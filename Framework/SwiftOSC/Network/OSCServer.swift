import Foundation
import Network

public class OSCServer {
    
    public var delegate: OSCDelegate?
    
    var listener: NWListener?
    var port: NWEndpoint.Port
    var queue: DispatchQueue
    var connection: NWConnection?
    
    public init?(port: Int) {
        
        // check port range
        if port > 65535 && port >= 0{
            NSLog("Invalid Port: Out of range.")
            return nil
        }
        
        self.port = NWEndpoint.Port(integerLiteral: UInt16(port))
        queue = DispatchQueue(label: "SwiftOSC Server")
        
        setupListener()
    }
    
    public func change(port: Int)->Bool{
        // check port range
        if port > 65535 && port >= 0{
            NSLog("Invalid Port: Out of range.")
            return false
        }
        self.port = NWEndpoint.Port(integerLiteral: UInt16(port))
        
        // destroy connection and listener
        connection?.forceCancel()
        listener?.cancel()
        
        // setup new listener
        setupListener()
        
        return true
    }
    
    func setupListener() {
        // create the listener
        listener = try! NWListener(using: .udp, on: port)
        
        // handle incoming connections server will only respond to the latest connection
        listener?.newConnectionHandler = { [weak self] (newConnection) in
            
            NSLog("New Connection from \(String(describing: newConnection))")
            
            // cancel previous connection
            if self?.connection != nil {
                NSLog("Cancelling connection: \(String(describing: newConnection))")
                self?.connection?.cancel()
            }
            
            self?.connection = newConnection
            self?.connection?.start(queue: (self?.queue)!)
            self?.receive()
        }
        
        // Handle listener state changes
        listener?.stateUpdateHandler = { [weak self] (newState) in
            switch newState {
            case .ready:
                NSLog("Listening on port \(String(describing: self?.listener?.port))")
            case .failed(let error):
                NSLog("Listener failed with error \(error)")
            case .cancelled:
                NSLog("Listener cancelled")
            default:
                break
            }
        }
        
        // start the listener
        listener?.start(queue: queue)
    }
    
    // receive
    func receive() {
        connection?.receiveMessage { [weak self] (content, context, isCompleted, error) in
            if let data = content {
                self?.decodePacket(data)
            }
            
            if error == nil && self?.connection != nil{
                self?.receive()
            }
        }
    }
    
    func decodePacket(_ data: Data){
        
        DispatchQueue.main.async {
            self.delegate?.didReceive(data)
        }
        
        if data[0] == 0x2f { // check if first character is "/"
            if let message = decodeMessage(data){
                self.sendToDelegate(message)
            }
            
        } else if data.count > 8 {//make sure we have at least 8 bytes before checking if a bundle.
            if "#bundle\0".toData() == data.subdata(in: Range(0...7)){//matches string #bundle
                if let bundle = decodeBundle(data){
                    self.sendToDelegate(bundle)
                }
            }
        } else {
            NSLog("Invalid OSCPacket: data must begin with #bundle\0 or /")
        }
    }
    
    func decodeBundle(_ data: Data)->OSCBundle? {
        
        //extract timetag
        let bundle = OSCBundle(OSCTimetag(data.subdata(in: 8..<16)))
        
        var bundleData = data.subdata(in: 16..<data.count)
        
        while bundleData.count > 0 {
            let length = Int(bundleData.subdata(in: Range(0...3)).toInt32())
            let nextData = bundleData.subdata(in: 4..<length+4)
            bundleData = bundleData.subdata(in:length+4..<bundleData.count)
            if "#bundle\0".toData() == nextData.subdata(in: Range(0...7)){//matches string #bundle
                if let newbundle = self.decodeBundle(nextData){
                    bundle.add(newbundle)
                } else {
                    return nil
                }
            } else if data[0] == 0x2f {
                
                if let message = self.decodeMessage(nextData) {
                    bundle.add(message)
                } else {
                    return nil
                }
            } else {
                NSLog("Invalid OSCBundle: Bundle data must begin with #bundle\0 or /.")
                return nil
            }
        }
        return bundle
    }
    
    func decodeMessage(_ data: Data)->OSCMessage?{
        var messageData = data
        var message: OSCMessage
        
        //extract address and check if valid
        if let addressEnd = messageData.index(of: 0x00){
            
            let addressString = messageData.subdata(in: 0..<addressEnd).toString()
            var address = OSCAddressPattern()
            if address.valid(addressString) {
                address.string = addressString
                message = OSCMessage(address)
                
                //extract types
                messageData = messageData.subdata(in: (addressEnd/4+1)*4..<messageData.count)
                let typeEnd = messageData.index(of: 0x00)!
                let type = messageData.subdata(in: 1..<typeEnd).toString()
                
                messageData = messageData.subdata(in: (typeEnd/4+1)*4..<messageData.count)
                
                for char in type {
                    switch char {
                    case "i"://int
                        message.add(Int(messageData.subdata(in: Range(0...3))))
                        messageData = messageData.subdata(in: 4..<messageData.count)
                    case "f"://float
                        message.add(Float(messageData.subdata(in: Range(0...3))))
                        messageData = messageData.subdata(in: 4..<messageData.count)
                    case "s"://string
                        let stringEnd = messageData.index(of: 0x00)!
                        message.add(String(messageData.subdata(in: 0..<stringEnd)))
                        messageData = messageData.subdata(in: (stringEnd/4+1)*4..<messageData.count)
                    case "b": //blob
                        var length = Int(messageData.subdata(in: Range(0...3)).toInt32())
                        messageData = messageData.subdata(in: 4..<messageData.count)
                        message.add(OSCBlob(messageData.subdata(in: 0..<length)))
                        while length%4 != 0 {//remove null ending
                            length += 1
                        }
                        messageData = messageData.subdata(in: length..<messageData.count)
                        
                    case "T"://true
                        message.add(true)
                    case "F"://false
                        message.add(false)
                    case "N"://null
                        message.add()
                    case "I"://impulse
                        message.add(OSCImpulse())
                    case "t"://timetag
                        message.add(OSCTimetag(messageData.subdata(in: Range(0...7))))
                        messageData = messageData.subdata(in: 8..<messageData.count)
                    default:
                        NSLog("Invalid OSCMessage: Unknown OSC type.")
                        return nil
                    }
                }
            } else {
                NSLog("Invalid OSCMessage: Invalid address.")
                return nil
            }
            return message
        } else {
            NSLog("Invalid OSCMessage: Missing address terminator.")
            return nil
        }
    }
    func sendToDelegate(_ element: OSCElement){
        DispatchQueue.main.async {
            if let message = element as? OSCMessage {
                self.delegate?.didReceive(message)
            }
            if let bundle = element as? OSCBundle {
                self.delegate?.didReceive(bundle)
                for element in bundle.elements {
                    self.sendToDelegate(element)
                }
            }
        }
    }
    
    public func restart() {
        // destroy connection and listener
        connection?.forceCancel()
        listener?.cancel()
        
        // setup new listener
        setupListener()
    }
}