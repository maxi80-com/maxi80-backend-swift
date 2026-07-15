import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension Logger {

    func request(_ request: HTTPClientRequest) async {
        self.trace("\n - - - - - - - - - - OUTGOING - - - - - - - - - - \n")
        defer { self.trace("\n - - - - - - - - - -  END - - - - - - - - - - \n") }
        let urlAsString = request.url
        let urlComponents = URLComponents(string: urlAsString)
        let method = request.method.rawValue
        let path = "\(urlComponents?.path ?? "")"
        let query = "\(urlComponents?.query ?? "")"
        let host = "\(urlComponents?.host ?? "")"
        var output = """
            \(urlAsString) \n\n
            \(method) \(path)?\(query) HTTP/1.1 \n
            HOST: \(host)\n
            """

        for (key, value) in request.headers {
            output += "\(key): \(value)\n"
        }

        if let body = request.body,
            let bytes = try? await body.collect(upTo: 1024 * 1024)
        {  //1 Mb maximum
            output += "\n \(String(buffer: bytes))"
        }
        self.trace("\(output)")
    }

    func response(_ response: HTTPClientResponse, data: Data?, error: (any Error)?) {
        self.trace("\n - - - - - - - - - - INCOMING - - - - - - - - - - \n")
        defer { self.trace("\n - - - - - - - - - -  END - - - - - - - - - - \n") }
        var output = "HTTP \(response.status.code)\n"

        for (key, value) in response.headers {
            output += "\(key): \(value)\n"
        }

        if let data {
            output += "\n\(String(decoding: data, as: UTF8.self))\n"
        }
        if let error {
            output += "\nError: \(error)\n"
        }
        self.trace("\(output)")
    }
}
