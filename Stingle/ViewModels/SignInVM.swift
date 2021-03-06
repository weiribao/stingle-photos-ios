import Foundation

class SignInVM: NSObject {
	
	public func signIn(email:String?, password:String?, completionHandler: @escaping (Bool, Error?) -> Swift.Void) -> Bool {
		return SyncManager.signIn(email: email, password: password) { (status, error) in
			completionHandler(status, error)
		}
	}
	
	private func validateEmail(email:String) -> Bool{
		return true
	}
	
	private func validatePassord(email:String) -> Bool{
		return true
	}
	
}
