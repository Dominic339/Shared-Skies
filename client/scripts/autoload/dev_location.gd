extends Node

# Developer-mode simulated GPS -- core infrastructure per the Phase 1 plan,
# not a later debugging afterthought, since neither device GPS nor
# real-world field testing against Nashua landmarks is practical during
# normal development.
#
# Stub for now -- filled in during Phase 1 step 6 (manual lat/lng entry +
# local WASD/drag movement, feeding Main's PlayerMarker).

var current_lat: float = 42.7654  # Nashua, NH default
var current_lng: float = -71.4676
