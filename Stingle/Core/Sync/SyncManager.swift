import Foundation
import UIKit
import CoreData

enum DeleteEvent: Int {
	case trash = 1
	case restore = 2
	case delete = 3
}

enum Set : Int {
	case Null = 0
	case Empty = 1
	case Gallery = 2
	case Trash = 3
	case Album = 4
}

class SyncManager {

	public static let db = DataBase.shared
	private static let fileManager = SPFileManager()
	private static let crypto = Crypto()
	
	static func signUp(email:String?, password:String?, completionHandler: @escaping (Bool, Error?) -> Swift.Void) -> Bool {
		guard let email = email, let password = password else {
			return false
		}
		var request:SPSignUpRequest? = nil
		do {
			try crypto.generateMainKeypair(password: password)
			guard let pwdHash = try crypto.getPasswordHashForStorage(password: password) else {
				completionHandler(false, nil)
				return false
			}
			guard let salt = pwdHash["salt"] else {
				completionHandler(false, nil)
				return false
			}
			guard let pwd = pwdHash["hash"] else {
				completionHandler(false, nil)
				return false
			}
			guard let keyBundle = try KeyManagement.getUploadKeyBundle(password: password, includePrivateKey: true) else {
				completionHandler(false, nil)
				return false
			}
			request = SPSignUpRequest(email: email, password: pwd, salt: salt, keyBundle: keyBundle, isBackup: true)

		} catch {
			completionHandler(false, error)
			return false
		}
		guard let signUpRequest = request else {
			completionHandler(false, nil)
			return false
		}
		_ = NetworkManager.send(request:signUpRequest) { (data:SPSignUpResponse?, error)  in
			guard let data = data, error == nil else {
				completionHandler(false, error)
				return
			}
			if data.status == "ok" {
				_ = SyncManager.signIn(email: email, password: password) { (status, error) in
					completionHandler(status, error)
				}
			}
		}
		return true
	}

	static func signOut( completionHandler: @escaping (Bool, Error?) -> Swift.Void) -> Bool {
		let request = SPSignOutRequest(token: SPApplication.user!.token)
		_ = NetworkManager.send(request:request) { (data:SPSignOutResponse?, error)  in
			guard let data = data, error == nil else {
				completionHandler(false, error)
				return
			}
			completionHandler(data.status == "ok", nil)
		}

		return false
	}

	
	static func signIn(email:String?, password:String?, completionHandler: @escaping (Bool, Error?) -> Swift.Void) -> Bool {
		guard let email = email, let password = password else {
			return false
		}
		
		let request = SPPreSignInRequest(email: email)
		_ = NetworkManager.send(request:request) { (data:SPPreSignInResponse?, error)  in do {
			guard let data = data, error == nil else {
				completionHandler(false, error)
				return
			}
			let pHash = try crypto.getPasswordHashForStorage(password: password, salt: data.parts.salt)
			let request = SPSignInRequest(email: email, password: pHash)
			_ = NetworkManager.send(request: request) { (data:SPSignInResponse?, error) in do {
				guard let data = data, error == nil else {
					completionHandler(false, error)
					return
				}
				let isKeyBackedUp:Bool = (data.parts.isKeyBackedUp == 1)
				SPApplication.user = User(token: data.parts.token, userId: data.parts.userId, isKeyBackedUp: isKeyBackedUp, homeFolder: data.parts.homeFolder, email: email)
				if KeyManagement.key == nil {
					guard true == KeyManagement.importKeyBundle(keyBundle: data.parts.keyBundle, password: password) else {
						print("Can't import key bundle")
						return
					}
					if isKeyBackedUp {
						KeyManagement.key = try self.crypto.getPrivateKey(password: password)
					}
					let pubKey = data.parts.serverPublicKey
					KeyManagement.importServerPublicKey(pbk: pubKey)
				}
				completionHandler(true, nil)
			} catch {
				completionHandler(false, error)
				}
			}
		} catch {
			completionHandler(false, error)
			}
		}
		return false
	}

	
	static func update(completionHandler:  @escaping (Bool) -> Swift.Void) {
		guard let info = db.getAppInfo() else {
			return
		}
//		let request = SPGetUpdateRequest(token: SPApplication.user!.token, lastSeen: "\(info.lastSeen)", lastDelSeenTime: "\(info.lastDelSeen)")
		let request = SPGetUpdateRequest(token: SPApplication.user!.token, lastSeen: "0", lastDelSeenTime: "0")

		_ = NetworkManager.send(request: request) { (data:SPUpdateInfo?, error:Error?) in
			guard let data = data , error == nil else {
				print(error.debugDescription)
				completionHandler(false)
				return
			}
			let timeinterval = Date.init().millisecondsSince1970
			self.db.updateAppInfo(info: AppInfo(lastSeen: timeinterval, lastDelSeen: info.lastDelSeen, spaceQuota: data.parts.spaceQuota, spaceUsed: data.parts.spaceUsed))
			processDeletes(deletes: data.parts.deletes)
			processFiles(files: data.parts.files)
			processFiles(files: data.parts.trash)
			completionHandler(true)
			EventManager.dispatch(event: SPEvent(type: SPEvent.DB.update.appInfo.rawValue, info:nil))
		}
		return
	}
	
	static func base64urlToBase64(base64url: String) -> String {
		var base64 = base64url
			.replacingOccurrences(of: "-", with: "+")
			.replacingOccurrences(of: "_", with: "/")
		if base64.count % 4 != 0 {
			base64.append(String(repeating: "=", count: 4 - base64.count % 4))
		}
		return base64
	}
	
	static func deleteFileFromPhone (file:SPFileInfo) {
		do {
			if let path = SPFileManager.folder(for: .StorageThumbs)?.appendingPathComponent(file.name) {
				try fileManager.removeItem(at: path)
			}
			if let path = SPFileManager.folder(for: .StorageOriginals)?.appendingPathComponent(file.name) {
				try fileManager.removeItem(at: path)
			}
		} catch {
			print(error)
		}
	}
	
	static func processDeletes(deletes:[SPDeletedFile]) {
		for file in deletes {
			if file.type == DeleteEvent.trash.rawValue {
				if let fileToDelete:SPFile = db.isFileExist(name: file.name) {
					if let deletedFile:SPTrashFile = db.delete(file: fileToDelete) {
						db.add(files: [deletedFile])
					}
				}
			} else if file.type == DeleteEvent.restore.rawValue {
				if let fileToDelete:SPTrashFile = db.isFileExist(name: file.name) {
					if let deletedFile:SPFile = db.delete(file: fileToDelete) {
						db.add(files: [deletedFile])
					}
				}
			} else if file.type == DeleteEvent.delete.rawValue {
				if let fileToDelete:SPTrashFile = db.isFileExist(name: file.name) {
					if let deletedFile:SPFile = db.delete(file: fileToDelete) {
						if let fileToRemove:SPFile = db.delete(file: deletedFile) {
							deleteFileFromPhone(file: fileToRemove)
						}
					}
				}
			}
		}
	}

	
	static func processFiles<T:SPFileInfo>(files:[T]) {
		var folder = NSNotFound
		var type = SPEvent.DB.update.gallery.rawValue
		if T.self is SPFile.Type {
				folder = 0
		} else if T.self is SPTrashFile.Type {
			folder = 1
			type = SPEvent.DB.update.trash.rawValue
		}
		for file in files {
			var needUpdate = false
			var needDownload = false
			if let oldFile:T = db.isFileExist(name: file.name) {
				if (oldFile.dateModified as NSString).integerValue < (file.dateModified as NSString).integerValue {
					needUpdate = true
				}
				if let isRemote = file.isRemote, !isRemote {
					needUpdate = true
				}
				if file.version > oldFile.version {
					needUpdate = true
					needDownload = true
				}
			} else {
				db.add(files: [file])
				let headers = file.headers
				let hdrs = headers.split(separator: "*")
				for hdr in hdrs {
					
					let st = base64urlToBase64(base64url: String(hdr))

					if let data = crypto.base64ToByte(data: st) {
						let input = InputStream(data: Data(data))
						input.open()
						do {
							if let header = try crypto.getFileHeader(input: input) {
								file.duration = header.videoDuration
							}
						} catch {
							print(error)
						}
						input.close()
					}

				}
				self.downloadThumbs(files: [file], folder: folder) { (fileName, error) in
					if let indexPath = db.indexPath(for: file.name, with: T.self) {
					EventManager.dispatch(event: SPEvent(type: type, info:[SPEvent.Keys.IndexPaths.rawValue : [indexPath]]))
					}
				}
			}
			if needUpdate {
				_ = db.updateFile(file: file)
//				if let indexPath = db.indexPath(for: file.name, with: T.self) {
//				EventManager.dispatch(event: SPEvent(type: type, info:[SPEvent.Keys.IndexPaths.rawValue : [indexPath]]))
//				}
			}
			if needDownload {
				self.downloadThumbs(files: [file], folder: folder) { (fileName, error) in
					guard let fileName = fileName, error == nil else {
						print(error.debugDescription)
						return
					}
					if let indexPath = db.indexPath(for: fileName, with: T.self) {
					EventManager.dispatch(event: SPEvent(type: type, info:[SPEvent.Keys.IndexPaths.rawValue : [indexPath]]))
					}
				}
				//TODO: Download when original image or video is requested
//				self.downloadFiles(files: [file], folder: folder) { (fileName, error) in
//				}
			}
		}
	}
	
	static func downloadFiles <T:SPFileInfo>(files:[T], folder:Int, completionHandler:  @escaping (String?, Error?) -> Swift.Void) {
		download(files: files, isThumb: false, folder: folder, completionHandler: completionHandler)
	}

	static func downloadThumbs <T:SPFileInfo>(files:[T], folder:Int, completionHandler:  @escaping (String?, Error?) -> Swift.Void) {
		download(files: files, isThumb: true, folder: folder, completionHandler: completionHandler)
	}

	static func download <T:SPFileInfo>(files:[T], isThumb: Bool, folder:Int, completionHandler:  @escaping (String?, Error?) -> Swift.Void) {
		for item in files {
			let request = SPDownloadFileRequest(token: SPApplication.user!.token, fileName: item.name, isThumb: isThumb, folder:folder)
			_ = NetworkManager.download(request: request) { (url, error) in
				if error != nil {
					completionHandler(nil, error)
				} else {
					completionHandler(item.name, nil)
				}
			}
		}
	}

		static func moveFiles(files:[SPFileInfo], from:Set, to:Set) -> Bool {
			
			if from == Set.Gallery && to == Set.Trash {
				if SyncManager.notifyCloudAboutTrash(files: files) {
					for file in files {
						let trashFile:SPTrashFile = file as! SPTrashFile
						guard let f:SPFile = db.delete(file: trashFile) else {
							return false
						}
						f.dateModified = "\(Date.init().millisecondsSince1970)"
						db.add(files: [f])
					}
				} else {
					return false
				}
			} else if from == Set.Trash && to == Set.Gallery {
				if SyncManager.notifyCloudAboutRestore(files: files) {
					for file in files {
						let trashFile:SPFile = file as! SPFile
						guard let f:SPTrashFile = db.delete(file: trashFile) else {
							return false
						}
						f.dateModified = "\(Date.init().millisecondsSince1970)"
						db.add(files: [f])
					}
				} else {
					return false
				}

			}
			return true
		}
	
	static func notifyCloudAboutTrash(files:[SPFileInfo]) -> Bool {
		let request = SPTrashFilesRequest(token: SPApplication.user!.token, files: files)
		_ = NetworkManager.send(request: request) { (resp:SPTrashResponse?, err) in
			if resp?.status == "ok" {
				print(resp!)
			}
		}
		return false
	}

	static func notifyCloudAboutRestore(files:[SPFileInfo]) -> Bool {
		let request = SPRestoreFilesRequest(token: SPApplication.user!.token, files: files)
		_ = NetworkManager.send(request: request) { (resp:SPTrashResponse?, err) in
			if resp?.status == "ok" {
				print(resp!)
			}
		}
		return false
	}

	static func notifyCloudAboutDelete(files:[SPFileInfo]) -> Bool {
		let request = SPDeleteFilesRequest(token: SPApplication.user!.token, files: files)
		_ = NetworkManager.send(request: request) { (resp:SPTrashResponse?, err) in
			if resp?.status == "ok" {
				print(resp!)
			}
		}
		return false
	}

	static func notifyCloudAboutEmpty(files:[SPFileInfo]) -> Bool {
		let request = SPEmptyTrashRequest(token: SPApplication.user!.token, files: files)
		_ = NetworkManager.send(request: request) { (resp:SPTrashResponse?, err) in
			if resp?.status == "ok" {
				print(resp!)
			}
		}
		return false
	}

	
	
	static func importImage(file:SPFile, thumb:UIImage?) {
		guard let fileName = Utils.getNewEncFilename() else {
			return
		}
		
		guard let fileId = crypto.newFileId() else {
			return
		}
		guard let data = file.data else {
			return
		}
		
		guard let thumbData = thumb?.pngData() as Data? else {
			return
		}
		let inputThumb = InputStream(data: thumbData)
		inputThumb.open()
		guard let thumbPath = SPFileManager.folder(for: .StorageThumbs)?.appendingPathComponent(fileName) else {
			return
		}
		guard let outputThumb = OutputStream(toFileAtPath: thumbPath.path, append: false) else {
			return
		}
		outputThumb.open()
		let inputOrigin = InputStream(data: data)
		inputOrigin.open()
		guard let originalPath = SPFileManager.folder(for: .StorageOriginals)?.appendingPathComponent(fileName) else {
			return
		}
		guard let outputOrigin = OutputStream(toFileAtPath: originalPath.path, append: false) else {
			return
		}
		outputOrigin.open()
		do {
			guard let type = file.type else {
				throw CryptoError.General.incorrectParameterSize
			}
			try crypto.encryptFile(input: inputThumb, output: outputThumb, filename: file.name, fileType: type, dataLength: UInt(thumbData.count), fileId: fileId, videoDuration: file.duration)
			inputThumb.close()
			outputThumb.close()
			try crypto.encryptFile(input: inputOrigin, output: outputOrigin, filename: file.name, fileType: type, dataLength: UInt(data.count), fileId: fileId, videoDuration: file.duration)
			inputOrigin.close()
			outputOrigin.close()
			guard let headers = try SPApplication.crypto.getFileHeaders(originalPath: originalPath.path, thumbPath: thumbPath.path) else {
				//TODO : throw right exception
				throw CryptoError.General.incorrectParameterSize
			}
			file.headers = headers
			file.name = fileName
			db.add(files: [file])
			NetworkManager.upload(file: file, folder: 0) { (space, quota, error) in
				if nil == error {
					db.marFileAsRemote(file: file)
					let indexPath = db.indexPath(for: file.name, with: SPFile.self)
					EventManager.dispatch(event: SPEvent(type: SPEvent.DB.update.gallery.rawValue, info:[SPEvent.Keys.IndexPaths.rawValue : [indexPath]]))
				}
			}
		} catch {
			print(error)
		}
	}
	
	deinit {
	}
	
}
