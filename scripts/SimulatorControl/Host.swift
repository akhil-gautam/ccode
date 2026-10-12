import SwiftUI
@main struct ControlHost: App {
    var body: some Scene { WindowGroup { VStack { Text("ccode simulator fixture").accessibilityIdentifier("fixture.title"); TextField("Fixture input",text:.constant("")).accessibilityIdentifier("fixture.input") }.padding() } }
}
