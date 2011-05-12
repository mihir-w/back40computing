/******************************************************************************
 * 
 * Copyright 2010-2011 Duane Merrill
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 * 
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 ******************************************************************************/

/******************************************************************************
 * Upsweep BFS Compaction kernel
 ******************************************************************************/

#pragma once

#include <b40c/util/cta_work_distribution.cuh>
#include <b40c/util/cta_work_progress.cuh>
#include <b40c/util/kernel_runtime_stats.cuh>

#include <b40c/bfs/compact_atomic/cta.cuh>

namespace b40c {
namespace bfs {
namespace compact_atomic {


/**
 * Sweep expansion pass (non-workstealing)
 */
template <typename KernelConfig, bool WORK_STEALING>
struct SweepPass
{
	template <typename SmemStorage>
	static __device__ __forceinline__ void Invoke(
		typename KernelConfig::VertexId 		&queue_index,
		typename KernelConfig::VertexId 		*&d_in,
		typename KernelConfig::VertexId 		*&d_parent_in,
		typename KernelConfig::VertexId 		*&d_out,
		typename KernelConfig::VertexId 		*&d_parent_out,
		typename KernelConfig::CollisionMask 	*&d_collision_cache,
		util::CtaWorkProgress 					&work_progress,
		util::CtaWorkDistribution<typename KernelConfig::SizeT> &work_decomposition,
		SmemStorage								&smem_storage)
	{
		typedef Cta<KernelConfig, SmemStorage> 		Cta;
		typedef typename KernelConfig::SizeT 		SizeT;

		// Determine our threadblock's work range
		util::CtaWorkLimits<SizeT> work_limits;
		work_decomposition.template GetCtaWorkLimits<
			KernelConfig::LOG_TILE_ELEMENTS,
			KernelConfig::LOG_SCHEDULE_GRANULARITY>(work_limits);

		// Return if we have no work to do
		if (!work_limits.elements) {
			return;
		}

		// CTA processing abstraction
		Cta cta(
			queue_index,
			smem_storage,
			d_in,
			d_parent_in,
			d_out,
			d_parent_out,
			d_collision_cache,
			work_progress);

		// Process full tiles
		while (work_limits.offset < work_limits.guarded_offset) {

			cta.ProcessTile(work_limits.offset);
			work_limits.offset += KernelConfig::TILE_ELEMENTS;
		}

		// Clean up last partial tile with guarded-i/o
		if (work_limits.guarded_elements) {
			cta.ProcessTile(
				work_limits.offset,
				work_limits.guarded_elements);
		}
	}
};


template <typename SizeT, typename QueueIndex>
__device__ __forceinline__ SizeT StealWork(
	util::CtaWorkProgress &work_progress,
	int count,
	QueueIndex queue_index)
{
	__shared__ SizeT s_offset;		// The offset at which this CTA performs tile processing, shared by all

	// Thread zero atomically steals work from the progress counter
	if (threadIdx.x == 0) {
		s_offset = work_progress.Steal<SizeT>(count, queue_index);
	}

	__syncthreads();		// Protect offset

	return s_offset;
}



/**
 * Sweep expansion pass (workstealing)
 */
template <typename KernelConfig>
struct SweepPass <KernelConfig, true>
{
	template <typename SmemStorage>
	static __device__ __forceinline__ void Invoke(
		typename KernelConfig::VertexId 		&queue_index,
		typename KernelConfig::VertexId 		*&d_in,
		typename KernelConfig::VertexId 		*&d_parent_in,
		typename KernelConfig::VertexId 		*&d_out,
		typename KernelConfig::VertexId 		*&d_parent_out,
		typename KernelConfig::CollisionMask 	*&d_collision_cache,
		util::CtaWorkProgress 					&work_progress,
		util::CtaWorkDistribution<typename KernelConfig::SizeT> &work_decomposition,
		SmemStorage								&smem_storage)
	{
		typedef Cta<KernelConfig, SmemStorage> 		Cta;
		typedef typename KernelConfig::SizeT 		SizeT;

		// CTA processing abstraction
		Cta cta(
			queue_index,
			smem_storage,
			d_in,
			d_parent_in,
			d_out,
			d_parent_out,
			d_collision_cache,
			work_progress);

		// Total number of elements in full tiles
		SizeT unguarded_elements = work_decomposition.num_elements & (~(KernelConfig::TILE_ELEMENTS - 1));

		// Worksteal full tiles, if any
		SizeT offset;
		while ((offset = StealWork<SizeT>(work_progress, KernelConfig::TILE_ELEMENTS, queue_index)) < unguarded_elements) {
			cta.ProcessTile(offset);
		}

		// Last CTA does any extra, guarded work (first tile seen)
		if (blockIdx.x == gridDim.x - 1) {
			SizeT guarded_elements = work_decomposition.num_elements - unguarded_elements;
			cta.ProcessTile(unguarded_elements, guarded_elements);
		}
	}
};


/******************************************************************************
 * Sweep Compaction Kernel Entrypoint
 ******************************************************************************/

/**
 * Compaction kernel entry point
 */
template <typename KernelConfig, bool INSTRUMENT>
__launch_bounds__ (KernelConfig::THREADS, KernelConfig::CTA_OCCUPANCY)
__global__
void Kernel(
	typename KernelConfig::VertexId			queue_index,
	volatile int							*d_done,
	typename KernelConfig::VertexId 		*d_in,
	typename KernelConfig::VertexId 		*d_parent_in,
	typename KernelConfig::VertexId 		*d_out,
	typename KernelConfig::VertexId 		*d_parent_out,
	typename KernelConfig::CollisionMask 	*d_collision_cache,
	util::CtaWorkProgress 					work_progress,
	util::KernelRuntimeStats				kernel_stats)
{
	typedef typename KernelConfig::SizeT SizeT;

	// Shared storage for CTA processing
	__shared__ typename KernelConfig::SmemStorage smem_storage;

	if (INSTRUMENT && (threadIdx.x == 0)) {
		kernel_stats.MarkStart();
	}

	// Determine work decomposition
	if (threadIdx.x == 0) {
		// Obtain problem size
		SizeT num_elements = work_progress.template LoadQueueLength<SizeT>(queue_index);

		// Signal to host that we're done
		if (num_elements == 0) {
			d_done[0] = 1;
		}

		// Initialize work decomposition in smem
		smem_storage.state.work_decomposition.template Init<KernelConfig::LOG_SCHEDULE_GRANULARITY>(
			num_elements, gridDim.x);

		// Reset our next outgoing queue counter to zero
		work_progress.template StoreQueueLength<SizeT>(0, queue_index + 2);

		// Reset our next workstealing counter to zero
		work_progress.template PrepResetSteal<SizeT>(queue_index + 1);
	}

	// Barrier to protect work decomposition
	__syncthreads();

	SweepPass<KernelConfig, KernelConfig::WORK_STEALING>::Invoke(
		queue_index,
		d_in,
		d_parent_in,
		d_out,
		d_parent_out,
		d_collision_cache,
		work_progress,
		smem_storage.state.work_decomposition,
		smem_storage);

	if (INSTRUMENT && (threadIdx.x == 0)) {
		kernel_stats.MarkStop();
		kernel_stats.Flush();
	}
}


} // namespace compact_atomic
} // namespace bfs
} // namespace b40c
