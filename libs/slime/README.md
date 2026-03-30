# Slime ECS

An experiment on ECS built in 3 days. Made for learning purposes and primarily for my game engine https://github.com/Tofaa2/framework
As framework was missing an in house entity component system that had prefabs and parallel scheduling and atomic getMut for components.
Slime is still very barebones and experimental, Ill be patching it up if i find stuff related to my engine

## Slime Prefabs
Prefabs for slime are essentially an id, mask and a set of components. There is a binary format for performance and a human readable/editable approach using json.

## Performance
Take these numbers with a grain of salt just like any performance tests. But for those of you who like numbers i guess here we go.
Tested on an AMD Ryzen AI MAX+ 395.

```
benchmark                         n      total_ms    ns/entity
----------------------------------------------------------------
spawn P+V                      1000000     52.847 ms             52 ns/op
query iterate P+V              1000000      0.701 ms              0 ns/op
chunked + columnSlice P        1000000      1.040 ms              1 ns/op
getMut via query P             1000000      8.182 ms              8 ns/op
spawnPrefab (same prefab)      1000000     63.061 ms             63 ns/op
addComponent V (migrate)       1000000     74.040 ms             74 ns/op
removeComponent V (migrate)    1000000     49.913 ms             49 ns/op
despawn                        1000000      9.569 ms              9 ns/op
```
