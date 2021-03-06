//
//  Created by Pierluigi Cifani on 03/06/15.
//  Copyright (c) 2016 Blurred Software SL. All rights reserved.
//

import Foundation
import Alamofire
import Deferred

/*
 Welcome to Drosky, your one and only way of talking to Rest APIs.
 
 Inspired by Moya (https://github.com/AshFurrow/Moya)
 
 */

/*
 Things to improve:
 1.- Wrap the network calls in a NSOperation in order to:
 * Control how many are being sent at the same time
 * Allow to add priorities in order to differentiate user facing calls to analytics crap
 2.- Use the Timeline data in Response to calculate an average of the responses from the server
 */


// MARK:- DroskyResponse

public struct DroskyResponse {
    public let statusCode: Int
    public let httpHeaderFields: [String: String]
    public let data: Data
}

extension DroskyResponse {
    func dataPrettyPrinted() -> String? {
        guard let dictionary = dataAsJSON() else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: .prettyPrinted) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func dataAsJSON() -> [String: AnyObject]? {
        let json: [String: AnyObject]?
        do {
            json = try JSONSerialization.jsonObject(with: self.data, options: JSONSerialization.ReadingOptions.allowFragments) as? [String: AnyObject]
        } catch {
            json = nil
        }
        
        return json
    }
}

extension DroskyResponse: CustomStringConvertible {
    public var description: String {
        return  "StatusCode: "  + String(statusCode) +
                "\nHeaders: "   +  httpHeaderFields.description +
                "\nData: "      +  (dataPrettyPrinted() ?? "no-data")
    }
}


// MARK: - Drosky

public final class Drosky {

    enum Constants {
        static let ModuleName = "drosky"
    }

    fileprivate let networkManager: Alamofire.SessionManager
    fileprivate let backgroundNetworkManager: Alamofire.SessionManager
    fileprivate let queue = queueForSubmodule(Constants.ModuleName, qualityOfService: .userInitiated)
    fileprivate let gcdQueue = DispatchQueue(label: Constants.ModuleName)
    fileprivate let dataSerializer = Alamofire.DataRequest.dataResponseSerializer()
    var router: Router
    
    public init (
        environment: Environment,
        signature: Signature? = nil,
        backgroundSessionID: String = Drosky.backgroundID()) {

        let serverTrustPolicies: [String: ServerTrustPolicy] = {
            guard !environment.shouldAllowInsecureConnections else {
                return [:]
            }
            return [environment.basePath: .disableEvaluation]
        }()
        
        let serverTrustManager = ServerTrustPolicyManager(policies: serverTrustPolicies)
        
        networkManager = Alamofire.SessionManager(
            configuration: URLSessionConfiguration.default,
            serverTrustPolicyManager: serverTrustManager
        )
        
        backgroundNetworkManager = Alamofire.SessionManager(
            configuration: URLSessionConfiguration.background(withIdentifier: backgroundSessionID),
            serverTrustPolicyManager: serverTrustManager
        )
        router = Router(environment: environment, signature: signature)
        queue.underlyingQueue = gcdQueue
    }
    
    public func setAuthSignature(_ signature: Signature?) {
        router = Router(environment: router.environment, signature: signature)
    }

    public func setEnvironment(_ environment: Environment) {
        router = Router(environment: environment, signature: router.signature)
    }
    
    public func performRequest(forEndpoint endpoint: Endpoint) -> Task<DroskyResponse> {
        return generateRequest(forEndpoint: endpoint)
                ≈> sendRequest
                ≈> processResponse
    }
    
    public func performRequest(_ request: URLRequest) -> Task<DroskyResponse> {
        return  sendRequest(request)
            ≈> processResponse
    }

    public func performAndValidateRequest(forEndpoint endpoint: Endpoint) -> Task<DroskyResponse> {
        return performRequest(forEndpoint: endpoint)
                ≈> validateDroskyResponse
    }

    public func performMultipartUpload(forEndpoint endpoint: Endpoint, multipartParams: [MultipartParameter], backgroundTask: Bool = false) -> Task<DroskyResponse> {
        
        guard case let .success(request) = router.urlRequest(forEndpoint: endpoint) else {
            return Task(failure: DroskyErrorKind.badRequest)
        }
        
        return performUpload(request, multipartParameters: multipartParams, backgroundTask: backgroundTask)
                ≈> processResponse
    }

    //MARK:- Internal
    private func generateRequest(forEndpoint endpoint: Endpoint) -> Task<URLRequestConvertible> {
        
        let deferred = Deferred<TaskResult<URLRequestConvertible>>()
        
        let operation = BlockOperation { [weak self] in
            guard let strongSelf = self else { return }
            let requestResult = strongSelf.router.urlRequest(forEndpoint: endpoint)
            deferred.fill(with: requestResult)
        }
        
        queue.addOperation(operation)
        return Task(future: Future(deferred), cancellation: {
            operation.cancel()
        })
    }
    
    
    private func sendRequest(_ request: URLRequestConvertible) -> Task<(Data, HTTPURLResponse)> {
        let deferred = Deferred<TaskResult<(Data, HTTPURLResponse)>>()
        
        let request = networkManager
            .request(request)
            .responseData(queue: gcdQueue) { self.processAlamofireResponse($0, deferred: deferred) }
        
        return Task(future: Future(deferred), cancellation: {
            request.cancel()
        })
    }
    
    private func performUpload(_ request: URLRequestConvertible, multipartParameters: [MultipartParameter], backgroundTask: Bool) -> Task<(Data, HTTPURLResponse)> {
        let deferredResponse = Deferred<TaskResult<(Data, HTTPURLResponse)>>()
        let workToBeDone = Int64(100)
        let progress = Progress.discreteProgress(totalUnitCount: workToBeDone)

        let manager: Alamofire.SessionManager = backgroundTask ? backgroundNetworkManager : networkManager
        manager.upload(
            multipartFormData: { (form) in
                multipartParameters.forEach { param in
                    switch param.parameterValue {
                    case .url(let url):
                        form.append(url, withName: param.parameterKey)
                    case .data(let data):
                        form.append(data, withName: param.parameterKey)
                    }
                }
            },
            with: request,
            encodingCompletion: { (result) in
                switch result {
                case .failure(let error):
                    deferredResponse.fill(with: .failure(error))
                case .success(let request, _,  _):
                    progress.addChild(request.uploadProgress, withPendingUnitCount: workToBeDone)
                    progress.cancellationHandler = {
                        self.gcdQueue.async { request.cancel() }
                    }
                    request.responseData(queue: self.gcdQueue) {
                        self.processAlamofireResponse($0, deferred: deferredResponse)
                    }
                }
            }
        )
        
        return Task(future: Future(deferredResponse), progress: progress)
    }
    
    private func processResponse(_ data: Data, urlResponse: HTTPURLResponse) -> Task<DroskyResponse> {
        
        let deferred = Deferred<TaskResult<DroskyResponse>>()
        
        let operation = BlockOperation {
            let droskyResponse = DroskyResponse(
                statusCode: urlResponse.statusCode,
                httpHeaderFields: urlResponse.headers,
                data: data
            )
            
            #if DEBUG
                if let message = JSONParser.errorMessageFromData(droskyResponse.data) {
                    print(message)
                }
            #endif
            
            deferred.fill(with: .success(droskyResponse))
        }
        
        queue.addOperation(operation)
        return Task(future: Future(deferred), cancellation: {
            operation.cancel()
        })
    }
    
    private func validateDroskyResponse(_ response: DroskyResponse) -> Task<DroskyResponse> {
        
        let deferred = Deferred<TaskResult<DroskyResponse>>()
        
        let operation = BlockOperation {
            switch response.statusCode {
            case 200...299:
                deferred.fill(with: .success(response))
            case 400:
                deferred.fill(with: .failure(DroskyErrorKind.badRequest))
            case 401:
                deferred.fill(with: .failure(DroskyErrorKind.unauthorized))
            case 403:
                deferred.fill(with: .failure(DroskyErrorKind.forbidden))
            case 404:
                deferred.fill(with: .failure(DroskyErrorKind.resourceNotFound))
            case 405...499:
                deferred.fill(with: .failure(DroskyErrorKind.unknownResponse))
            case 500:
                deferred.fill(with: .failure(DroskyErrorKind.serverUnavailable))
            default:
                deferred.fill(with: .failure(DroskyErrorKind.unknownResponse))
            }
        }
        
        queue.addOperation(operation)
        return Task(future: Future(deferred), cancellation: {
            operation.cancel()
        })
    }

    private func processAlamofireResponse(_ response: DataResponse<Data>, deferred: Deferred<TaskResult<(Data, HTTPURLResponse)>>) {
        switch response.result {
        case .failure(let error):
            deferred.fill(with: .failure(error))
        case .success(let data):
            guard let response = response.response else { fatalError() }
            deferred.fill(with: .success(data, response))
        }
    }
}

//MARK: Background handling

extension Drosky {
    
    fileprivate static func backgroundID() -> String {
        let appName = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String ?? Constants.ModuleName
        return "\(appName)-\(Foundation.UUID().uuidString)"
    }

    public var backgroundSessionID: String {
        get {
            guard let sessionID = backgroundNetworkManager.session.configuration.identifier else { fatalError("This should have a sessionID") }
            return sessionID
        }
    }
    
    public func completedBackgroundTasksURL() -> Future<[URL]> {
        
        let deferred = Deferred<[URL]>()
        
        backgroundNetworkManager.delegate.sessionDidFinishEventsForBackgroundURLSession = { session in
            
            session.getTasksWithCompletionHandler { (dataTasks, _, _) -> Void in
                let completedTasks = dataTasks.filter { $0.state == .completed && $0.originalRequest?.url != nil}
                deferred.fill(with: completedTasks.map { return $0.originalRequest!.url!})
                self.backgroundNetworkManager.backgroundCompletionHandler?()
            }
        }
        
        return Future(deferred)
    }

}

//MARK:- Errors

public enum DroskyErrorKind: Error {
    case unknownResponse
    case unauthorized
    case serverUnavailable
    case resourceNotFound
    case formattedError
    case malformedURLError
    case forbidden
    case badRequest
}


extension HTTPURLResponse {
    var headers: [String: String] {
        //TODO: Rewrite using map
        var headers: [String: String] = [:]
        for tuple in allHeaderFields {
            if let key = tuple.0 as? String, let value = tuple.1 as? String {
                headers[key] = value
            }
        }
        return headers
    }
}
