#include <stdio.h>


#include <b40/reduce.cuh>
#include <cub/io.cuh>
#include <cub/operators.cuh>


int main()
{
	typedef int T;

	T *d_in = NULL;
	T *d_out = NULL;
	T *h_out = NULL;
	T *h_seed = NULL;

	b40::Reduce(d_in, d_out, h_out, h_seed, 5);

	b40::reduction::Policy<
		b40::reduction::KernelPolicy<32, 1, 1, cub::READ_NONE, cub::WRITE_NONE, false>,
		b40::reduction::KernelPolicy<32, 1, 1, cub::READ_NONE, cub::WRITE_NONE, false>,
		true,
		true> policy;

	cub::Sum<T> reduction_op;

	b40::Reduce(d_in, d_out, h_out, h_seed, 5, reduction_op, policy);

	return 0;
}