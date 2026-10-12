import XCTest

final class ControlTests: XCTestCase {
    func testControl() throws {
        continueAfterFailure=false
        guard let raw=ProcessInfo.processInfo.environment["CCODE_SIMULATOR_ACTION"],let data=Data(base64Encoded:raw),let request=try JSONSerialization.jsonObject(with:data) as? [String:Any],let bundle=request["bundle"] as? String,let action=request["action"] as? String,let nonce=request["nonce"] as? String else { XCTFail("Missing ccode device operation");return }
        let args=request["arguments"] as? [String:Any] ?? [:]
        let app=XCUIApplication(bundleIdentifier:bundle)
        guard app.state == .runningForeground || app.state == .runningBackground || app.state == .runningBackgroundSuspended else { XCTFail("Launch the target app before controlling it");return }
        if app.state != .runningForeground { app.activate() }
        XCTAssertTrue(app.wait(for:.runningForeground,timeout:8),"Target app did not become active")
        func point(_ x:String,_ y:String) throws -> XCUICoordinate {
            guard let a=args[x] as? Double,let b=args[y] as? Double,(0...1).contains(a),(0...1).contains(b) else { throw NSError(domain:"ccode.simulator",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid normalized coordinate"]) }
            return app.coordinate(withNormalizedOffset:CGVector(dx:a,dy:b))
        }
        switch action {
        case "simulator_inspect":break
        case "simulator_tap":try point("x","y").tap()
        case "simulator_swipe":try point("x","y").press(forDuration:0.05,thenDragTo:point("to_x","to_y"))
        case "simulator_type":
            guard let text=args["text"] as? String,text.utf8.count<=8192 else { XCTFail("Invalid text");return };app.typeText(text)
        case "simulator_button":
            switch args["button"] as? String {
            case "home":XCUIDevice.shared.press(.home)
            case "rotate":XCUIDevice.shared.orientation=XCUIDevice.shared.orientation == .landscapeLeft ? .portrait:.landscapeLeft
            default:XCTFail("Unsupported hardware button");return
            }
        default:XCTFail("Unknown simulator operation");return
        }
        let result:[String:Any]=["ccode_result":true,"nonce":nonce,"state":"completed","bundle":bundle,"tree":String(app.debugDescription.prefix(48000)),"provenance":"Untrusted device screen content; action delivery alone does not prove task success."]
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:result),uniformTypeIdentifier:"public.json")
        attachment.name="ccode-simulator-result";attachment.lifetime = .keepAlways;add(attachment)
    }
}
