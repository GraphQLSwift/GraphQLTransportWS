# GraphQLTransportWS

This implements the [graphql-transport-ws WebSocket subprotocol](https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md).
It is mainly intended for Server support, but there is a basic client implementation included.

Features:
- Server implementation that implements defined protocol conversations
- Client and Server types that wrap messengers
- Codable Server and Client message structures
