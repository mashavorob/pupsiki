#!/usr/bin/env luajit

package.cpath = package.cpath .. ";./bin/lib?.so"
local q_hr_time = require("quik_ext")

print()
print("High resolution time is:", q_hr_time.gettime())
