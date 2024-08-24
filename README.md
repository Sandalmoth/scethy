# scethy

Experimental entity component system (ECS) designed around the ability to efficiently snapshot the
entire state of all entities.

Check 
[the benchmark](src/benchmark.zig) 
and a 
[snake demo](https://github.com/Sandalmoth/snake-tests/tree/master/v2) 
for usage examples.

## Possible issues
- Copying can fail when there are many identical copies present (no simple verification...)
