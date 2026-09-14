# trigger-router/src/test/java/com/noxos/triggerrouter/classifier/ModelUpdateManagerTest.kt

## `` `checking again before the staleness window elapses does not contact the server` ``

Both fake servers are stopped after the first check. A second check within the staleness
window must not attempt any real request, or this would hang/fail against the now-dead
sockets — that's what actually proves the staleness gate works, not just that it returns
the right enum value.
