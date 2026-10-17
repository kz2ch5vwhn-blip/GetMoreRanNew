//
//  FetchAnisetteDataOperation.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CryptoKit
import StosSign_API
import StosSign_Auth
import StosSign_Common

final class AnisetteDataHelper
{
    var socket: URLSessionWebSocketTask?
    
    var url: URL?
    var startProvisioningURL: URL?
    var endProvisioningURL: URL?
    
    var clientInfo: String?
    var userAgent: String?
    
    var mdLu: String?
    var deviceId: String?
    
    var menuAnisetteURL: String?
    
    static var shared: AnisetteDataHelper = AnisetteDataHelper()
    
    var loggingFunc: ((String)->Void)?
    
    func resetClientInfo() {
        clientInfo = nil
        userAgent = nil
        mdLu = nil
        deviceId = nil
    }
    
    func getAnisetteData(refresh: Bool = false) async throws -> AnisetteData
    {
        
        // Always use the server that is currently configured in Settings
        self.url = AnisetteSettings.serverURL
        
        if url == nil {
            throw "No Anisette Server Found!"
        }
        
        self.printOut("Anisette URL: \(self.url!.absoluteString)")
        
        // Decide which client info / user agent is presented to Apple and drop
        // provisioning data that was created for a different server or identity.
        await self.resolveIdentity()
        
        let ans : AnisetteData
        if let identifier = Keychain.shared.identifier,
           let adiPb = Keychain.shared.adiPb {
            ans = try await self.fetchAnisetteV3(identifier, adiPb)
        } else {
            ans = try await self.provision()
        }
        return ans
    }
    
    // MARK: - COMMON
    
    func extractAnisetteData(_ data: Data, _ response: HTTPURLResponse?, v3: Bool) async throws -> AnisetteData {
        // make sure this JSON is in the format we expect
        // convert data to json
        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
            if v3 {
                if json["result"] == "GetHeadersError" {
                    let message = json["message"]
                    self.printOut("Error getting V3 headers: \(message ?? "no message")")
                    if let message = message,
                       message.contains("-45061") {
                        self.printOut("Error message contains -45061 (not provisioned), resetting adi.pb and retrying")
                        Keychain.shared.adiPb = nil
                        return try await provision()
                    } else { throw message ?? "Unknown error" }
                }
            }
            
            // try to read out a dictionary
            // for some reason serial number isn't needed but it doesn't work unless it has a value
            var formattedJSON: [String: String] = ["deviceSerialNumber": "0"]
            if let machineID = json["X-Apple-I-MD-M"] { formattedJSON["machineID"] = machineID }
            if let oneTimePassword = json["X-Apple-I-MD"] { formattedJSON["oneTimePassword"] = oneTimePassword }
            if let routingInfo = json["X-Apple-I-MD-RINFO"] { formattedJSON["routingInfo"] = routingInfo }
            
            if v3 {
                formattedJSON["deviceDescription"] = self.clientInfo!
                formattedJSON["localUserID"] = self.mdLu!
                formattedJSON["deviceUniqueIdentifier"] = self.deviceId!
                
                // Generate date stuff on client
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone.current
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
                let dateString = formatter.string(from: Date())
                self.printOut("Client time (UTC): \(dateString)")
                formattedJSON["date"] = dateString
                formattedJSON["locale"] = "en_US"
                formattedJSON["timeZone"] = "UTC"
            } else {
                if let deviceDescription = json["X-MMe-Client-Info"] { formattedJSON["deviceDescription"] = deviceDescription }
                if let localUserID = json["X-Apple-I-MD-LU"] { formattedJSON["localUserID"] = localUserID }
                if let deviceUniqueIdentifier = json["X-Mme-Device-Id"] { formattedJSON["deviceUniqueIdentifier"] = deviceUniqueIdentifier }
                
                if let date = json["X-Apple-I-Client-Time"] { formattedJSON["date"] = date }
                if let locale = json["X-Apple-Locale"] { formattedJSON["locale"] = locale }
                if let timeZone = json["X-Apple-I-TimeZone"] { formattedJSON["timeZone"] = timeZone }
            }
            
            if let response = response,
               let version = response.value(forHTTPHeaderField: "Implementation-Version") {
                self.printOut("Implementation-Version: \(version)")
            } else { self.printOut("No Implementation-Version header") }
            
            self.printOut("Server returned: \(json.keys.sorted().joined(separator: ", "))")
            self.printOut("Anisette used: \(formattedJSON)")
            self.printOut("Original JSON: \(json)")
            do {
                let jsonData = try JSONEncoder().encode(formattedJSON)
                let anisette = try JSONDecoder().decode(AnisetteData.self, from: jsonData)
                
                self.printOut("Anisette is valid!")
                return anisette
            } catch {
                self.printOut("Anisette is invalid!!!!")
                if v3 {
                    throw "Invalid anisette (the returned data may not have all the required fields)"
                } else {
                    throw "Invalid anisette (the returned data may not have all the required fields)"
                }
            }
        } else {
            if v3 {
                throw "Invalid anisette (the returned data may not be in JSON)"
            } else {
                throw "Invalid anisette (the returned data may not be in JSON)"
            }
        }
    }
    
    
    // MARK: - V3: PROVISIONING
    
    func provision() async throws -> AnisetteData {
        try await fetchClientInfo()
            self.printOut("Getting provisioning URLs")
            var request = self.buildAppleRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!)
            request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        if
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let startProvisioningString = plist["urls"]?["midStartProvisioning"] as? String,
           let startProvisioningURL = URL(string: startProvisioningString),
           let endProvisioningString = plist["urls"]?["midFinishProvisioning"] as? String,
           let endProvisioningURL = URL(string: endProvisioningString) {
            self.startProvisioningURL = startProvisioningURL
            self.endProvisioningURL = endProvisioningURL
            self.printOut("startProvisioningURL: \(self.startProvisioningURL!.absoluteString)")
            self.printOut("endProvisioningURL: \(self.endProvisioningURL!.absoluteString)")
            self.printOut("Starting a provisioning session")
            return try await self.startProvisioningSession()
        } else {
            self.printOut("Apple didn't give valid URLs! Got response: \(String(data: data, encoding: .utf8) ?? "not utf8")")
            throw "Apple didn't give valid URLs. Please try again later"
        }

        
    }
    
    func startProvisioningSession() async throws -> AnisetteData {
        let provisioningSessionURL = self.webSocketURL(from: self.url!.appendingPathComponent("v3").appendingPathComponent("provisioning_session"))
        var wsRequest = URLRequest(url: provisioningSessionURL)
        wsRequest.timeoutInterval = 5
        let socket = URLSession.shared.webSocketTask(with: wsRequest)
        self.socket = socket
        socket.resume()
        try await self.receiveProvisioningMessages(from: socket)
        return try await self.fetchAnisetteV3(Keychain.shared.identifier!, Keychain.shared.adiPb!)
    }

    private func receiveProvisioningMessages(from socket: URLSessionWebSocketTask) async throws {
        self.printOut("Connected")
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket {
                self.socket = nil
            }
        }
        
        while true {
            let message = try await socket.receive()
            switch message {
            case .string(let string):
                if try await handleProvisioningMessage(string, socket: socket) {
                    return
                }
            case .data:
                throw "The server sent binary data instead of text"
            @unknown default:
                throw "The server sent an unknown WebSocket message"
            }
        }
    }
    
    private func handleProvisioningMessage(_ string: String, socket: URLSessionWebSocketTask) async throws -> Bool {
        guard let data = string.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw "The server didn't give valid JSON"
        }
        
        guard let result = json["result"] as? String else {
            self.printOut("The server didn't give us a result")
            throw "The server didn't give us a result"
        }
        
        self.printOut("Received result: \(result)")
        switch result {
        case "GiveIdentifier":
            self.printOut("Giving identifier")
            try await socket.sendJSON(["identifier": Keychain.shared.identifier!])
            
        case "GiveStartProvisioningData":
            self.printOut("Getting start provisioning data")
            let spim = try await self.fetchStartProvisioningData()
            self.printOut("Giving start provisioning data")
            try await socket.sendJSON(["spim": spim])
            
        case "GiveEndProvisioningData":
            self.printOut("Getting end provisioning data")
            guard let cpim = json["cpim"] as? String else {
                self.printOut("The server didn't give us a cpim")
                throw "The server didn't give us a cpim"
            }
            let endProvisioningData = try await self.fetchEndProvisioningData(cpim: cpim)
            self.printOut("Giving end provisioning data")
            try await socket.sendJSON(endProvisioningData)
            
        case "ProvisioningSuccess":
            self.printOut("Provisioning succeeded!")
            guard let adiPb = json["adi_pb"] as? String else {
                self.printOut("The server didn't give us an adi.pb file")
                throw "The server didn't give us an adi.pb file"
            }
            Keychain.shared.adiPb = adiPb
            return true
            
        default:
            if result.contains("Error") || result.contains("Invalid") || result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                self.printOut("Failing because of \(result)")
                throw result + (json["message"] as? String ?? "")
            }
        }
        
        return false
    }
    
    private func fetchStartProvisioningData() async throws -> String {
        let body = [
            "Header": [String: Any](),
            "Request": [String: Any](),
        ]
        var request = self.buildAppleRequest(url: self.startProvisioningURL!)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let spim = plist["Response"]?["spim"] as? String {
            return spim
        } else {
            self.printOut("Apple didn't give valid start provisioning data! Got response: \(String(data: data, encoding: .utf8) ?? "not utf8")")
            throw "Apple didn't give valid start provisioning data. Please try again later"
        }
    }
    
    private func fetchEndProvisioningData(cpim: String) async throws -> [String: String] {
        let body = [
            "Header": [String: Any](),
            "Request": [
                "cpim": cpim,
            ],
        ]
        var request = self.buildAppleRequest(url: self.endProvisioningURL!)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let ptm = plist["Response"]?["ptm"] as? String,
           let tk = plist["Response"]?["tk"] as? String {
            return ["ptm": ptm, "tk": tk]
        } else {
            self.printOut("Apple didn't give valid end provisioning data! Got response: \(String(data: data, encoding: .utf8) ?? "not utf8")")
            throw "Apple didn't give valid end provisioning data. Please try again later"
        }
    }
    
    private func webSocketURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        
        return components.url ?? url
    }
    
    func buildAppleRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(self.clientInfo!, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(self.userAgent!, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        request.setValue(self.mdLu!, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(self.deviceId!, forHTTPHeaderField: "X-Mme-Device-Id")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let dateString = formatter.string(from: Date())
        request.setValue(dateString, forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue("en_US", forHTTPHeaderField: "X-Apple-Locale")
        request.setValue("UTC", forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }
    
    // MARK: - V3: FETCHING
    
    func fetchClientInfo() async throws {
        if self.clientInfo == nil || self.userAgent == nil {
            await self.resolveIdentity()
        }
        
        if  self.mdLu != nil &&
                self.deviceId != nil &&
                Keychain.shared.identifier != nil {
            self.printOut("Skipping client_info fetch since all the properties we need aren't nil")
            return
        }
        
        if Keychain.shared.identifier == nil {
            self.printOut("Generating identifier")
            var bytes = [Int8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            
            if status != errSecSuccess {
                self.printOut("ERROR GENERATING IDENTIFIER!!! \(status)")
                throw "Couldn't generate identifier"
            }
            
            Keychain.shared.identifier = Data(bytes: &bytes, count: bytes.count).base64EncodedString()
        }
        
        let decoded = Data(base64Encoded: Keychain.shared.identifier!)!
        self.mdLu = decoded.sha256().hexEncodedString()
        self.printOut("X-Apple-I-MD-LU: \(self.mdLu!)")
        let uuid: UUID = decoded.object()
        self.deviceId = uuid.uuidString.uppercased()
        self.printOut("X-Mme-Device-Id: \(self.deviceId!)")

        // Client info on Anisette Servers are out of date for latest GSA
        /*
        let clientInfoURL = self.url!.appendingPathComponent("v3").appendingPathComponent("client_info")
        
        let (data, response) = try await URLSession.shared.data(from: clientInfoURL)
        

            do {
                
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
                    if let clientInfo = json["client_info"] {
                        self.printOut("Server is V3")
                        
                        self.clientInfo = clientInfo
                        self.userAgent = json["user_agent"]!
                        self.printOut("Client-Info: \(self.clientInfo!)")
                        self.printOut("User-Agent: \(self.userAgent!)")
                        
                        if Keychain.shared.identifier == nil {
                            self.printOut("Generating identifier")
                            var bytes = [Int8](repeating: 0, count: 16)
                            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                            
                            if status != errSecSuccess {
                                self.printOut("ERROR GENERATING IDENTIFIER!!! \(status)")
                                throw "Couldn't generate identifier"
                            }
                            
                            Keychain.shared.identifier = Data(bytes: &bytes, count: bytes.count).base64EncodedString()
                        }
                        
                        let decoded = Data(base64Encoded: Keychain.shared.identifier!)!
                        self.mdLu = decoded.sha256().hexEncodedString()
                        self.printOut("X-Apple-I-MD-LU: \(self.mdLu!)")
                        let uuid: UUID = decoded.object()
                        self.deviceId = uuid.uuidString.uppercased()
                        self.printOut("X-Mme-Device-Id: \(self.deviceId!)")
                        
                        return
                    } else { throw "v1 server is not supported" }
                } else { throw "Couldn't fetch client info. The returned data may not be in JSON" }
            }
        */
    }
    
    func fetchAnisetteV3(_ identifier: String, _ adiPb: String) async throws -> AnisetteData {
        try await fetchClientInfo()
        self.printOut("Fetching anisette V3")
        let url = menuAnisetteURL
        var request = URLRequest(url: self.url!.appendingPathComponent("v3").appendingPathComponent("get_headers"))
        request.httpMethod = "POST"
        request.httpBody = try! JSONSerialization.data(withJSONObject: [
            "identifier": identifier,
            "adi_pb": adiPb
        ], options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        
        return try await self.extractAnisetteData(data, response as? HTTPURLResponse, v3: true)

    }
    
    
    // MARK: - Identity (client info + user agent)
    
    /// Forces one specific identity for the current sign-in (used for the -80045 fallback).
    var identityOverride: AnisetteIdentity?
    
    /// Decides which X-MMe-Client-Info / User-Agent pair is presented to Apple.
    ///
    /// Since 2026-10-12 Apple's GrandSlam answers most identities with error -80045, so the
    /// identity has to match what the Anisette server generated its data for.
    func resolveIdentity() async {
        let identity: AnisetteIdentity
        
        if let forced = identityOverride {
            self.printOut("Using the fallback identity")
            identity = forced
        } else {
            switch AnisetteSettings.mode {
            case .windows:
                self.printOut("Using the Windows (iTunes) identity")
                identity = AnisetteIdentity.windows
            case .custom:
                let customInfo = AnisetteSettings.customClientInfo
                let customAgent = AnisetteSettings.customUserAgent
                if customInfo.isEmpty || customAgent.isEmpty {
                    self.printOut("The custom identity is incomplete, using the Windows (iTunes) identity")
                    identity = AnisetteIdentity.windows
                } else {
                    self.printOut("Using the custom identity")
                    identity = AnisetteIdentity(clientInfo: customInfo, userAgent: customAgent)
                }
            case .auto:
                if let reported = await self.fetchServerIdentity() {
                    self.printOut("Using the identity reported by the Anisette server")
                    identity = reported
                } else {
                    self.printOut("The Anisette server did not report an identity, using the Windows (iTunes) identity")
                    identity = AnisetteIdentity.windows
                }
            }
        }
        
        self.clientInfo = identity.clientInfo
        self.userAgent = identity.userAgent
        self.printOut("Client-Info: \(identity.clientInfo)")
        self.printOut("User-Agent: \(identity.userAgent)")
        
        // StosSign reads the user agent for its GrandSlam requests from here (patched in by build.yml)
        let defaults = UserDefaults.standard
        defaults.set(identity.userAgent, forKey: AnisetteSettings.stosSignUserAgentKey)
        
        // Provisioning data (adi.pb + identifier) is only valid for the server and identity it was
        // created with, so start from scratch whenever one of them changes.
        let fingerprint = "\(self.url?.absoluteString ?? "")|\(identity.clientInfo)|\(identity.userAgent)"
        let previous = defaults.string(forKey: AnisetteSettings.fingerprintKey)
        if previous != fingerprint {
            if defaults.bool(forKey: AnisetteSettings.keepProvisioningOnceKey) {
                self.printOut("Keeping the imported provisioning data")
            } else {
                self.printOut("Anisette server or identity changed, clearing old provisioning data")
                Keychain.shared.adiPb = nil
                Keychain.shared.identifier = nil
                self.mdLu = nil
                self.deviceId = nil
            }
            defaults.set(fingerprint, forKey: AnisetteSettings.fingerprintKey)
        }
        defaults.removeObject(forKey: AnisetteSettings.keepProvisioningOnceKey)
    }
    
    /// Asks the Anisette server which client info / user agent its data belongs to.
    func fetchServerIdentity() async -> AnisetteIdentity? {
        guard let baseURL = self.url else { return nil }
        
        var request = URLRequest(url: baseURL.appendingPathComponent("v3").appendingPathComponent("client_info"))
        request.timeoutInterval = 10
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.printOut("client_info request failed with HTTP \(http.statusCode)")
                return nil
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let clientInfo = (json["client_info"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let userAgent = (json["user_agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !clientInfo.isEmpty,
                  !userAgent.isEmpty else {
                self.printOut("client_info response is not in the expected format")
                return nil
            }
            
            return AnisetteIdentity(clientInfo: clientInfo, userAgent: userAgent)
        } catch {
            self.printOut("Couldn't fetch client_info: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Used by the "Test Server" button in Settings.
    func testServer() async -> String {
        guard let serverURL = AnisetteSettings.serverURL else {
            return "The Anisette server URL is not valid."
        }
        self.url = serverURL
        
        if let identity = await self.fetchServerIdentity() {
            return "Server: \(serverURL.absoluteString)\n\nClient info:\n\(identity.clientInfo)\n\nUser agent:\n\(identity.userAgent)"
        }
        return "Server: \(serverURL.absoluteString)\n\nThe server did not report a client info / user agent (/v3/client_info). In Auto mode the Windows identity is used instead. Check the URL or try another server."
    }
    
    private func printOut(_ text: String?){
        let isInternalLoggingEnabled = true
        if(isInternalLoggingEnabled){
            // logging enabled, so log it
            if let loggingFunc {
                loggingFunc(text ?? "\n")
            } else {
                text.map{ _ in print(text!) } ?? print()
            }

        }
    }
}

extension URLSessionWebSocketTask {
    func sendJSON(_ dictionary: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [])
        try await self.send(.string(String(data: data, encoding: .utf8)!))
    }
}

extension Data {
    // https://stackoverflow.com/a/25391020
    func sha256() -> Data {
        Data(SHA256.hash(data: self))
    }
    
    // https://stackoverflow.com/a/40089462
    func hexEncodedString() -> String {
        return self.map { String(format: "%02hhX", $0) }.joined()
    }
    
    // https://stackoverflow.com/a/59127761
    func object<T>() -> T { self.withUnsafeBytes { $0.load(as: T.self) } }
}


// MARK: - Anisette identity settings

enum AnisetteIdentityMode: String, CaseIterable, Identifiable {
    case auto
    case windows
    case custom
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .auto: return "Auto (from server)"
        case .windows: return "Windows (iTunes)"
        case .custom: return "Custom"
        }
    }
}

struct AnisetteIdentity: Equatable {
    var clientInfo: String
    var userAgent: String
    
    /// The identity that iTunes for Windows uses. This is what SideStore / iloader switched to on 2026-10-14.
    static let windows = AnisetteIdentity(
        clientInfo: "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>",
        userAgent: "akd/1.0 CFNetwork/808.1.4"
    )
}

enum AnisetteSettings {
    /// Default server since 2026-10-16 (the default of iloader 2.3.9).
    static let defaultServer = "https://mac-ani.jkcoxson.com"
    /// Old defaults that Apple's GrandSlam rejects with -80045. They are replaced once.
    static let legacyDefaultServers = ["https://ani.sidestore.io"]
    
    static let serverKey = "AnisetteServer"
    static let modeKey = "AnisetteIdentityMode"
    static let customClientInfoKey = "AnisetteCustomClientInfo"
    static let customUserAgentKey = "AnisetteCustomUserAgent"
    static let fingerprintKey = "AnisetteIdentityFingerprint"
    static let keepProvisioningOnceKey = "AnisetteKeepProvisioningOnce"
    static let migrationKey = "AnisetteDefaultServerMigration202610"
    static let stosSignUserAgentKey = "GetMoreRam.GSAUserAgent"
    
    static var serverString: String {
        let stored = UserDefaults.standard.string(forKey: serverKey) ?? defaultServer
        var trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? defaultServer : trimmed
    }
    
    static var serverURL: URL? {
        return URL(string: serverString)
    }
    
    static var mode: AnisetteIdentityMode {
        get {
            return AnisetteIdentityMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
        }
    }
    
    static var customClientInfo: String {
        return (UserDefaults.standard.string(forKey: customClientInfoKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    static var customUserAgent: String {
        return (UserDefaults.standard.string(forKey: customUserAgentKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Replaces the old default server once, so existing installs move to a server Apple still accepts.
    static func migrateLegacyServerIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)
        
        guard let stored = defaults.string(forKey: serverKey) else { return }
        var normalized = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if normalized.isEmpty || legacyDefaultServers.contains(normalized) {
            defaults.set(defaultServer, forKey: serverKey)
        }
    }
}
