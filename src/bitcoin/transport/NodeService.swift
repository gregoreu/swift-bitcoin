import Foundation
import AsyncAlgorithms

public actor NodeService: Sendable {

    public enum Error: Swift.Error, Sendable {
        case connectionToSelf, unsupportedVersion, unsupportedServices, invalidPayload, missingWTXIDRelayPreference, requestedWTXIDRelayAfterVerack, missingV2AddrPreference, requestedV2AddrAfterVerack, pingPongMismatch, unsupportedCompactBlocksVersion
    }

    public struct Peer: Sendable {
        public let address: IPv6Address
        public let port: Int
        public let incoming: Bool

        /// Our version was acknowledged by the peer.
        var sentVersion = false
        var receivedVersion = false

        /// BIP339
        var sentWTXIDRelayPreference = false

        /// BIP339
        var receivedWTXIDRelayPreference = false

        /// BIP155
        var receivedV2AddressPreference = false

        /// BIP155
        var sentV2AddressPreference = false

        var sentVersionAck = false
        var receivedVersionAck = false

        /// BIP152
        var sentCompactBlocksPreference = false

        /// BIP152
        var highBandwidthCompactBlocks = false

        /// BIP152
        /// We really only support version 2 compact blocks.
        var compactBlocksVersion = Int?.none

        /// BIP152
        var compactBlocksVersionLocked = false

        /// BIP152: Holding pong until our compact block version was sent.
        var pongOnHoldUntilCompactBlocksPreference = PongMessage?.none

        // Information from the version message sent by the peer
        var preferredVersion = ProtocolVersion?.none
        var userAgent = String?.none
        var addressDeclared = IPv6Address?.none
        var portDeclared = Int?.none
        var services = ProtocolServices?.none
        var relay = Bool?.none
        var nonce = UInt64?.none

        /// Difference between the time reported by the peer and our time at the time we receive the version message.
        var timeDiff = 0

        // Status
        public internal(set) var height = 0
        public internal(set) var lastPingNonce = UInt64?.none
        var receivedHeaders = [BlockHeader]?.none

        /// BIP133
        public internal(set) var feeFilterRate = BitcoinAmount?.none // TODO: Honor when relaying transacions (inv) to this peer, #188

        var outgoing: Bool { !incoming }

        /// The connection has been established.
        public var handshakeComplete: Bool {
            sentVersion &&
                receivedVersion &&
                sentWTXIDRelayPreference &&
                receivedWTXIDRelayPreference &&
                sentV2AddressPreference &&
                receivedV2AddressPreference &&
                sentVersionAck &&
                receivedVersionAck
        }
    }

    public init(bitcoinService: BitcoinService, network: NodeNetwork = .regtest, feeFilterRate: BitcoinAmount? = .none) {
        self.bitcoinService = bitcoinService
        self.network = network
        if let feeFilterRate {
            self.feeFilterRate = feeFilterRate
        }
    }

    public let bitcoinService: BitcoinService
    public let network: NodeNetwork

    /// Subscription to the bitcoin service's blocks channel.
    public var blocks = AsyncChannel<TransactionBlock>?.none

    /// IP address as string.
    var address = IPv6Address?.none

    /// Our port might not exist if peer-to-peer server is down. We can still be conecting with peers as a client.
    var port = Int?.none

    /// BIP133: Our current fee filter rate for transactions relayed to us by peers. Default: 1 satoshi per virtual byte (sat/vbyte).
    var feeFilterRate = BitcoinAmount(1) // TODO: Allow to be changed via RPC command, #189

    /// Peer information.
    public internal(set) var peers = [UUID : Peer]()

    /// Channel for delivering message to peers.
    var peerOuts = [UUID : AsyncChannel<BitcoinMessage>]()

    /// The node's randomly generated identifier (nonce). This is sent with `version` messages.
    let nonce = UInt64.random(in: UInt64.min ... UInt64.max)

    var awaitingHeadersFrom = UUID?.none
    var awaitingHeadersSince = Date?.none

    /// Called when the peer-to-peer service stops listening for incoming connections.
    public func resetAddress() {
        address = .none
        port = .none
    }

    /// Receive address information from the peer-to-peer service whenever it's actively listening.
    public func setAddress(_ host: String, _ port: Int) {
        self.address = IPv6Address.fromHost(host)
        self.port = port
    }

    /// We unsubscribe from Bitcoin service's blocks.
    public func stop() async throws {
        if let blocks {
            await bitcoinService.unsubscribe(blocks)
        }
    }

    /// Send a ping to each of our peers. Calling this function will create child tasks.
    public func pingAll() async {
        await withDiscardingTaskGroup {
            for id in peers.keys {
                $0.addTask {
                    await self.sendPingTo(id)
                }
            }
        }
    }

    /// Request headers from peers.
    public func requestHeaders() async {
        let maxHeight = peers.values.reduce(-1) { max($0, $1.height) }
        let ourHeight = await bitcoinService.blockchain.count
        guard maxHeight > ourHeight,
              let (id, _) = peers.filter({ $0.value.height == maxHeight }).randomElement() else {
            return
        }
        await requestHeaders(id)
    }

    /// Request headers from a specific peer.
    func requestHeaders(_ id: UUID) async {
        let locatorHashes = await bitcoinService.makeBlockLocator()
        let getHeaders = GetHeadersMessage(protocolVersion: Self.version, locatorHashes: locatorHashes)
        awaitingHeadersFrom = id
        awaitingHeadersSince = .now
        await send(.getheaders, payload: getHeaders.data, to: id)
    }


    /// Registers a peer with the node. Incoming means we are the listener. Otherwise we are the node initiating the connection.
    public func addPeer(host: String, port: Int, incoming: Bool = true) async -> UUID {
        let id = UUID()
        peers[id] = Peer(address: IPv6Address.fromHost(host), port: port, incoming: incoming)
        peerOuts[id] = .init()
        return id
    }

    /// Deregisters a peer and cleans up outbound channels.
    public func removePeer(_ id: UUID) {
        peerOuts[id]?.finish()
        peerOuts.removeValue(forKey: id)
        peers.removeValue(forKey: id)
    }

    /// Returns a channel for a given peer's outbox. The caller can be notified of new messages generated for this peer.
    public func getChannel(for id: UUID) -> AsyncChannel<BitcoinMessage> {
        precondition(peers[id] != nil)
        return peerOuts[id]!
    }

    func makeVersion(for id: UUID) async -> VersionMessage {
        guard let peer = peers[id] else { preconditionFailure() }

        let lastBlock = await bitcoinService.blockchain.count - 1
        return .init(
            protocolVersion: Self.version,
            services: Self.services,
            receiverServices: peer.services ?? .empty,
            receiverAddress: peer.addressDeclared ?? .unspecified,
            receiverPort: peer.portDeclared ?? 0,
            transmitterServices: Self.services,
            transmitterAddress: address ?? .unspecified,
            transmitterPort: port ?? 0,
            nonce: nonce,
            userAgent: Self.userAgent,
            startHeight: lastBlock,
            relay: true)
    }

    /// Starts the handshake process but only if its an outgoing peer – i.e. we initiated the connection. Generates a child task for delivering the initial version message.
    public func connect(_ id: UUID) async {
        guard let peer = peers[id], peer.outgoing else { return }

        let versionMessage = await makeVersion(for: id)
        print("Our version:")
        debugPrint(versionMessage)

        await send(.version, payload: versionMessage.data, to: id)
        peers[id]?.sentVersion = true
    }

    /// Sends a ping message to a peer. Creates a new child task.
    func sendPingTo(_ id: UUID) async {
        let ping = PingMessage()
        peers[id]?.lastPingNonce = ping.nonce
        await send(.ping, payload: ping.data, to: id)
    }

    /// Process an incoming message from a peer. This will sometimes result in sending out one or more messages back to the peer. The function will ultimately create a child task per message sent.
    public func processMessage(_ message: BitcoinMessage, from id: UUID) async throws {
        print("<- \(message.command) (\(message.payload.count))")
        switch message.command {
        case .version:
            try await processVersion(message, from: id)
        case .wtxidrelay:
            try await processWTXIDRelay(message, from: id)
        case .sendaddrv2:
            try await processSendAddrV2(message, from: id)
        case .verack:
            try await processVerack(message, from: id)
        case .sendcmpct:
            try processSendCompact(message, from: id)
        case .feefilter:
            try processFeeFilter(message, from: id)
        case .ping:
            try await processPing(message, from: id)
        case .pong:
            try processPong(message, from: id)
        case .getheaders:
            try await processGetHeaders(message, from: id)
        case .headers:
            try await processHeaders(message, from: id)
        case .getaddr, .addrv2, .inv, .getdata, .notfound, .unknown:
            break
        }
    }

    /// Sends a message.
    private func send(_ command: MessageCommand, payload: Data = .init(), to id: UUID) async {
        print("-> \(command) (\(payload.count))")
        await peerOuts[id]?.send(.init(network: network, command: command, payload: payload))
    }

    /// Processes an incoming version message as part of the handshake.
    private func processVersion(_ message: BitcoinMessage, from id: UUID) async throws {

        // Inbound connection sequence:
        // <- version (we receive the first message from the connecting peer)
        // -> version
        // -> wtxidrelay
        // -> sendaddrv2
        // <- verack
        // -> verack
        // -> sendcmpct
        // -> ping
        // -> getheaders
        // -> feefilter
        // <- pong

        guard let peer = peers[id] else { return }
        peers[id]?.receivedVersion = true

        let ourTime = Date.now

        guard let peerVersion = VersionMessage(message.payload) else {
            preconditionFailure()
        }

        print("Peer version:")
        debugPrint(peerVersion)

        if peerVersion.nonce == nonce {
            throw Error.connectionToSelf
        }

        if peerVersion.services.intersection(Self.services) != Self.services {
            throw Error.unsupportedServices
        }

        // Inbound connection. Version message is the first message.
        if peerVersion.protocolVersion < Self.version {
            throw Error.unsupportedVersion
        }

        peers[id]?.nonce = peerVersion.nonce
        peers[id]?.preferredVersion = peerVersion.protocolVersion
        peers[id]?.userAgent = peerVersion.userAgent
        peers[id]?.services = peerVersion.services
        peers[id]?.addressDeclared = peerVersion.transmitterAddress
        peers[id]?.portDeclared = peerVersion.transmitterPort
        peers[id]?.relay = peerVersion.relay
        peers[id]?.timeDiff = Int(ourTime.timeIntervalSince1970) - Int(peerVersion.timestamp.timeIntervalSince1970)
        peers[id]?.height = peerVersion.startHeight

        // Outbound connection. Version message is a response to our version.
        if peer.outgoing && peerVersion.protocolVersion > Self.version {
            throw Error.unsupportedVersion
        }

        if peer.incoming {
            let versionMessage = await makeVersion(for: id)

            print("Our version:")
            debugPrint(versionMessage)

            await send(.version, payload: versionMessage.data, to: id)
            peers[id]?.sentVersion = true
        }

        // BIP339
        await send(.wtxidrelay, to: id)
        peers[id]?.sentWTXIDRelayPreference = true

        // BIP155
        await send(.sendaddrv2, to: id)
        peers[id]?.sentV2AddressPreference = true

        await send(.verack, to: id)
        peers[id]?.sentVersionAck = true
    }

    /// BIP339
    private func processWTXIDRelay(_ message: BitcoinMessage, from id: UUID) async throws {
        guard let peer = peers[id] else { return }

        // Disconnect peers that send a WTXIDRELAY message after VERACK.
        if peer.receivedVersionAck {
            // Because we disconnect nodes that don't signal for WTXID relay, this code will never be reached.
            throw Error.requestedWTXIDRelayAfterVerack
        }

        peers[id]?.receivedWTXIDRelayPreference = true
    }

    /// BIP155
    private func processSendAddrV2(_ message: BitcoinMessage, from id: UUID) async throws {
        guard let peer = peers[id] else { return }

        // Disconnect peers that send a SENDADDRV2 message after VERACK.
        if peer.receivedVersionAck {
            // Because we disconnect nodes that don't ask for v2, this code will never be reached.
            throw Error.requestedV2AddrAfterVerack
        }

        peers[id]?.receivedV2AddressPreference = true
    }

    private func processVerack(_ message: BitcoinMessage, from id: UUID) async throws {
        guard let peer = peers[id] else { return }

        if peer.receivedVersionAck {
            // Ignore redundant verack.
            print("Redundant verack.")
            return
        }

        // BIP339
        if !peer.receivedWTXIDRelayPreference {
            throw Error.missingWTXIDRelayPreference
        }

        // BIP155
        if !peer.receivedV2AddressPreference {
            throw Error.missingV2AddrPreference
        }

        peers[id]?.receivedVersionAck = true

        if peers[id]!.handshakeComplete {
            print("Handshake successful.")
        }

        // BIP152 send a burst of supported compact block versions followed by a ping to lock it down.
        await send(.sendcmpct, payload: SendCompactMessage().data, to: id)
        peers[id]?.sentCompactBlocksPreference = true
        if let pong = peer.pongOnHoldUntilCompactBlocksPreference {
            await send(.pong, payload: pong.data, to: id)
            peers[id]?.pongOnHoldUntilCompactBlocksPreference = .none
        }
        await sendPingTo(id)

        await send(.feefilter, payload: FeeFilterMessage(feeRate: feeFilterRate).data, to: id)
    }

    private func processPing(_ message: BitcoinMessage, from id: UUID) async throws {
        guard let peer = peers[id] else { return }

        guard let ping = PingMessage(message.payload) else {
            throw Error.invalidPayload
        }
        debugPrint(ping)

        let pong = PongMessage(nonce: ping.nonce)
        debugPrint(pong)

        // BIP152 We need to hold the pong until the compact block version was sent.
        if peer.sentCompactBlocksPreference {
            await send(.pong, payload: pong.data, to: id)
        } else {
            peers[id]?.pongOnHoldUntilCompactBlocksPreference = pong
        }
    }

    private func processPong(_ message: BitcoinMessage, from id: UUID) throws {

        guard let peer = peers[id] else { return }

        guard let pong = PongMessage(message.payload) else {
            throw Error.invalidPayload
        }
        debugPrint(pong)
        guard let nonce = peers[id]?.lastPingNonce, pong.nonce == nonce else {
            throw Error.pingPongMismatch
        }
        peers[id]?.lastPingNonce = .none

        // BIP152: Lock compact block version on first pong.
        guard let compactBlocksVersion = peer.compactBlocksVersion, compactBlocksVersion >= Self.minCompactBlocksVersion else {
            throw Error.unsupportedCompactBlocksVersion
        }
        peers[id]?.compactBlocksVersionLocked = true
    }

    /// BIP152
    private func processSendCompact(_ message: BitcoinMessage, from id: UUID) throws {
        guard let peer = peers[id] else { return }

        guard let sendCompact = SendCompactMessage(message.payload) else {
            throw Error.invalidPayload
        }
        debugPrint(sendCompact)
        // We let the negotiation play out for versions lower than our max supported. When version is finally locked we will enforce our minimum supported version as well.
        if peer.compactBlocksVersion == .none, sendCompact.version <= Self.maxCompactBlocksVersion {
            peers[id]?.highBandwidthCompactBlocks = sendCompact.highBandwidth
            peers[id]?.compactBlocksVersion = sendCompact.version
        }
    }

    /// BIP133
    private func processFeeFilter(_ message: BitcoinMessage, from id: UUID) throws {
        guard let feeFilter = FeeFilterMessage(message.payload) else {
            throw Error.invalidPayload
        }
        debugPrint(feeFilter)
        peers[id]?.feeFilterRate = feeFilter.feeRate
    }

    private func processGetHeaders(_ message: BitcoinMessage, from id: UUID) async throws {
        guard let _ = peers[id] else { return }

        guard let getHeaders = GetHeadersMessage(message.payload) else {
            throw Error.invalidPayload
        }
        debugPrint(getHeaders)

        let headers = await bitcoinService.findHeaders(using: getHeaders.locatorHashes)
        let headersMessage = HeadersMessage(items: headers)
        debugPrint(headersMessage)

        await send(.headers, payload: headersMessage.data, to: id)
    }

    private func processHeaders(_ message: BitcoinMessage, from id: UUID) async throws {
        guard let _ = peers[id], let awaitingHeadersFrom, let awaitingHeadersSince, awaitingHeadersFrom == id else { return }

        self.awaitingHeadersFrom = .none
        self.awaitingHeadersSince = .none

        if awaitingHeadersSince.timeIntervalSinceNow < -60 {
            return
        }

        guard let headersMessage = HeadersMessage(message.payload) else {
            throw Error.invalidPayload
        }

        guard headersMessage.items.count > 0 else {
            return
        }
        let connectionPoint = headersMessage.items[0].previous

        guard let last = await bitcoinService.blockchain.last, connectionPoint == last.hash else {
            return
        }

        peers[id]?.receivedHeaders = headersMessage.items
        // TODO: Request blocks

        debugPrint(headersMessage)
    }

    static let version = ProtocolVersion.latest
    static let userAgent = "/SwiftBitcoin:0.1.0/"
    static let services = ProtocolServices.all
    static let minCompactBlocksVersion = 2
    static let maxCompactBlocksVersion = 2
}
