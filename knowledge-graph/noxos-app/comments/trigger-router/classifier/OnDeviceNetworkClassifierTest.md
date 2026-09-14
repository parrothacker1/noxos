# trigger-router/src/test/java/com/noxos/triggerrouter/classifier/OnDeviceNetworkClassifierTest.kt

## `modelJson` (test fixture)

A hand-written, deliberately tiny two-tree ensemble - not a real trained model - just
enough to prove the interpreter walks splits/leaves/defaults correctly. Real trees come
from noxos-inference's future model-export step (see knowledge-graph/noxos-inference/TASKS.md
for the exact JSON contract this test is exercising).

## `` `a missing feature falls back to the model's own bundled default` ``

dst_port omitted entirely - defaults to 443.0, which is < 1024 -> left leaf (-2.0),
same as if the caller had actually supplied 443f.
