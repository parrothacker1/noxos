# trigger-router/src/main/java/com/noxos/triggerrouter/classifier/OnDeviceNetworkClassifier.kt

## `OnDeviceNetworkClassifier` (class)

Evaluates a gradient-boosted tree ensemble dumped to the JSON shape documented in
knowledge-graph/noxos-inference/TASKS.md (a flat, hand-specified format - not XGBoost's own
`booster.dump_model` output - so this interpreter doesn't have to special-case index-based
`fN` feature names or XGBoost's nested `children` layout). Deliberately no TFLite/ONNX
dependency, matching this codebase's hand-rolled-over-dependency pattern (e.g. the TCP relay).

Internal representation mirrors noxos-inference's own service: trees predict attack
probability (higher = more dangerous); safetyScore is exposed inverted (1 - attackProbability)
to match noxos-app's "higher = safer" convention.
