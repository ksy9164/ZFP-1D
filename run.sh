#!/bin/bash

./bsim/obj/bsim &
export BDBM_BSIM_PID=$!
echo "running sw"
echo $BDBM_BSIM_PID
sleep 1
if [ "$1" == "gdb" ]
then
	gdb ./sw 
else
	./sw | tee res.txt
fi
sleep 3
./cpp/get_diff > result.txt
kill -9 $BDBM_BSIM_PID
rm /dev/shm/bdbm$BDBM_BSIM_PID
