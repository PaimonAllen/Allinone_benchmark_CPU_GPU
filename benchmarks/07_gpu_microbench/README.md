# 07_gpu_microbench

GPU kernel and instruction microbenchmarks.

Typical contents:

- CUDA Events based kernel timing harnesses.
- Empty kernel, launch latency, global memory, shared memory, register FMA,
  atomic, shuffle, and Tensor Core loop tests.
- Nsight Compute reports for occupancy, SM activity, memory throughput, and
  stall reasons.
