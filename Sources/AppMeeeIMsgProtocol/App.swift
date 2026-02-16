import AppMeeeIMsgCore
import Foundation

@main
struct AppMeeeIMsgProtocolApp {
    static func main() async {
        let router = CommandRouter()
        let status = await router.run()
        if status != 0 {
            exit(status)
        }
    }
}
