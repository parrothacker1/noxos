# netmonitor/src/test/java/com/noxos/netmonitor/TcpRelayManagerTest.kt

## `` `relays a full tcp handshake, data exchange, and close` ``

The mock server closes its socket right after writing "world", so its FIN can race
into this same window alongside our ack-for-data and the relayed reply - identify
each of the three by what it actually is, not by arrival order or a fixed count.
