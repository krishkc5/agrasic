#!/bin/bash
awk '/riscvTest_001 failed/,/riscvTest_002|running riscvTest_002/' /tmp/full_run.log | head -30
