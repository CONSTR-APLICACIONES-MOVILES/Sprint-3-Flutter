import Flutter
import UIKit
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mapsKey = ""
  private var placesChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ParchGooglePlaces") else { return }
    let channel = FlutterMethodChannel(name: "parchapp/google_places", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    placesChannel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "configure":
      let key = (args["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if key.isEmpty {
        result(false)
        return
      }
      if mapsKey.isEmpty {
        mapsKey = key
        GMSServices.provideAPIKey(key)
      }
      result(true)
    case "isConfigured":
      result(!mapsKey.isEmpty)
    case "endSession":
      result(nil)
    case "search":
      search(args, result: result)
    case "details":
      details(args, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func notConfigured() -> FlutterError {
    FlutterError(code: "MAPS_NOT_CONFIGURED", message: "Maps are unavailable in this build.", details: nil)
  }

  private func send(_ url: URL, body: [String: Any]?, fields: String?, completion: @escaping ([String: Any]?) -> Void) {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.setValue(mapsKey, forHTTPHeaderField: "X-Goog-Api-Key")
    request.setValue(Bundle.main.bundleIdentifier ?? "", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
    if let fields {
      request.setValue(fields, forHTTPHeaderField: "X-Goog-FieldMask")
    }
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    URLSession.shared.dataTask(with: request) { data, response, _ in
      let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
      let json = ok ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
      DispatchQueue.main.async { completion(json) }
    }.resume()
  }

  private func search(_ args: [String: Any], result: @escaping FlutterResult) {
    guard !mapsKey.isEmpty else {
      result(notConfigured())
      return
    }
    let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let session = args["session"] as? String ?? ""
    guard (3...200).contains(query.count) else {
      result([[String: String]]())
      return
    }
    guard (16...100).contains(session.count) else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid search session.", details: nil))
      return
    }
    let latitude = args["latitude"] as? Double ?? 4.60971
    let longitude = args["longitude"] as? Double ?? -74.08175
    let body: [String: Any] = [
      "input": query,
      "sessionToken": session,
      "includedRegionCodes": ["co"],
      "locationBias": ["circle": ["center": ["latitude": latitude, "longitude": longitude], "radius": 30000.0]],
    ]
    send(URL(string: "https://places.googleapis.com/v1/places:autocomplete")!, body: body, fields: nil) { json in
      guard let json else {
        result(FlutterError(code: "PLACES_SEARCH_FAILED", message: "Unable to search places right now.", details: nil))
        return
      }
      let suggestions = json["suggestions"] as? [[String: Any]] ?? []
      var rows: [[String: String]] = []
      for suggestion in suggestions {
        guard let prediction = suggestion["placePrediction"] as? [String: Any],
              let id = prediction["placeId"] as? String else { continue }
        let format = prediction["structuredFormat"] as? [String: Any]
        let main = (format?["mainText"] as? [String: Any])?["text"] as? String
        let full = (prediction["text"] as? [String: Any])?["text"] as? String
        let secondary = (format?["secondaryText"] as? [String: Any])?["text"] as? String
        rows.append(["id": id, "title": main ?? full ?? "", "address": secondary ?? ""])
      }
      result(rows)
    }
  }

  private func details(_ args: [String: Any], result: @escaping FlutterResult) {
    guard !mapsKey.isEmpty else {
      result(notConfigured())
      return
    }
    let id = args["id"] as? String ?? ""
    let session = args["session"] as? String ?? ""
    guard !id.isEmpty, id.count <= 300,
          let path = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          var components = URLComponents(string: "https://places.googleapis.com/v1/places/" + path) else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid place.", details: nil))
      return
    }
    if !session.isEmpty {
      components.queryItems = [URLQueryItem(name: "sessionToken", value: session)]
    }
    guard let url = components.url else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid place.", details: nil))
      return
    }
    send(url, body: nil, fields: "id,displayName,formattedAddress,location") { json in
      guard let json,
            let location = json["location"] as? [String: Any],
            let latitude = location["latitude"] as? Double,
            let longitude = location["longitude"] as? Double else {
        result(FlutterError(code: "PLACES_DETAILS_FAILED", message: "Unable to load this place.", details: nil))
        return
      }
      let name = (json["displayName"] as? [String: Any])?["text"] as? String ?? ""
      let address = json["formattedAddress"] as? String ?? ""
      let label = address.localizedCaseInsensitiveContains(name)
        ? address
        : [name, address].filter { !$0.isEmpty }.joined(separator: " · ")
      result([
        "latitude": latitude,
        "longitude": longitude,
        "label": String(label.prefix(500)),
        "placeId": json["id"] as? String ?? id,
      ])
    }
  }
}