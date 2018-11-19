#pragma once
#include <iostream>
#include <memory>
#include <algorithm>
#include <cuda.h>
#include <cuda_runtime.h>
#include <curand_kernel.h>
#include <math.h>

#include "graph/graph.h"
#include "coloring.h"
#include "GPUutils/GPUutils.h"
#include "GPUutils/GPURandomizer.h"

#define STATS
#define PRINTS

/**
* choose one to indicate how to initialize the colors
*/
//#define STANDARD_INIT
#define DISTRIBUTION_INIT

/**
* choose one to indicate the desired colorer
*/
//#define STANDARD
//#define STANDARD_CUMULATIVE						TODO
//#define COLOR_BALANCE_ON_NODE_CUMULATIVE
#define COLOR_DECREASE_LINE_CUMULATIVE
//#define COLOR_DECREASE_EXPONENT_CUMULATIVE		TODO
//#define COLOR_BALANCE_LINE_CUMULATIVE				TODO
//#define COLOR_BALANCE_EXPONENT_CUMULATIVE			TODO

template<typename nodeW, typename edgeW>
class ColoringMCMC : public Colorer<nodeW, edgeW> {
public:

	ColoringMCMC(Graph<nodeW, edgeW> * inGraph_d, curandState * randStates, ColoringMCMCParams params);
	~ColoringMCMC();

	void			run();

protected:
	uint32_t		nnodes;
	uint32_t		nedges;
	uint32_t		numOfColors;

	ColoringMCMCParams param;
	uint32_t		rip = 0;

	//dati del grafo
	const GraphStruct<nodeW, edgeW>	* const	graphStruct_d;

	int				conflictCounter;
	int				conflictCounterStar;

	//int *ret;

	uint32_t	*	conflictCounter_h; // lo spazio occupato pu� essere grande quanto blocksPerGrid_half_edges se si usa solo la somma parallela, vale anche per gli altri punti in cui si usa la somma parallela
	uint32_t	*	conflictCounter_d;


	float			result, random;

	uint32_t	*	coloring_d;			// each element denotes a color
	uint32_t	*	starColoring_d;		// each element denotes a new color
	uint32_t	*	switchPointer;

	float			p;
	float		*	q_h;
	float		*	q_d;				// each element denotes a probability for a color

	float			pStar;
	float		*	qStar_h;
	float		*	qStar_d;			// each element denotes a probability for a new color

	bool		*	colorsChecker_d;
#ifdef STANDARD
	uint32_t	*	orderedColors_d;
#endif // STANDARD
#if defined(DISTRIBUTION_INIT) || defined(COLOR_DECREASE_LINE_CUMULATIVE)
	float		*	probDistribution_d;
#endif // DISTRIBUTION_INIT || COLOR_DECREASE_LINE_CUMULATIVE

	// STATS
	uint32_t	*	coloring_h;			// each element denotes a color
	uint32_t	*	statsColors_h;		// used to get differents data from gpu memory
	uint32_t	*	statsFreeColors_d;	// used to see free colors for nodes
	uint32_t		statsFreeColors_max, statsFreeColors_min, statsFreeColors_avg;

	uint32_t		threadId;

	cudaError_t		cuSts;
	uint32_t		numThreads;
	dim3			threadsPerBlock;
	dim3			blocksPerGrid;
	dim3			blocksPerGrid_nCol;
	dim3			blocksPerGrid_half;
	dim3			blocksPerGrid_edges;
	dim3			blocksPerGrid_half_edges;
	curandState *	randStates;

	void			calcConflicts(int &conflictCounter, uint32_t * coloring_d);
	void			getStatsFreeColors();
	void			getStatsNumColors();
	void			calcProbs();
};


namespace ColoringMCMC_k {

#ifdef STANDARD_INIT
	__global__ void initColoring(uint32_t nnodes, uint32_t * coloring_d, float nCol, curandState * states);
#endif // STANDARD_INIT

#if defined(DISTRIBUTION_INIT) || defined(COLOR_DECREASE_LINE_CUMULATIVE)
	__global__ void initDistribution(float nCol, float denom, float lambda, float * probDistribution_d);
#endif
#ifdef DISTRIBUTION_INIT
	__global__ void initColoringWithDistribution(uint32_t nnodes, uint32_t * coloring_d, float nCol, float * probDistribution_d, curandState * states);
#endif // DISTRIBUTION_INIT || COLOR_DECREASE_LINE_CUMULATIVE

	__global__ void logarithmer(uint32_t nnodes, float * values);
	__global__ void conflictChecker(uint32_t nedges, uint32_t * conflictCounter_d, uint32_t * coloring_d, node_sz * edges);
	__global__ void sumReduction(uint32_t nedges, float * conflictCounter_d);
	__device__ void warpReduction(volatile float *sdata, uint32_t tid, uint32_t blockSize);

#ifdef STANDARD
	__global__ void selectStarColoring(uint32_t nnodes, uint32_t * starColoring_d, float * qStar_d, col_sz nCol, uint32_t * coloring_d, node_sz * cumulDegs, node * neighs, bool * colorsChecker_d, uint32_t * orderedColors_d, curandState * states, float epsilon, uint32_t * statsFreeColors_d);
#endif // STANDARD
#ifdef COLOR_BALANCE_ON_NODE_CUMULATIVE
	__global__ void selectStarColoringBalanceOnNode_cumulative(uint32_t nnodes, uint32_t * starColoring_d, float * qStar_d, col_sz nCol, uint32_t * coloring_d, node_sz * cumulDegs, node * neighs, bool * colorsChecker_d, curandState * states, float partition, float epsilon, uint32_t * statsFreeColors_d);
#endif // !COLOR_BALANCE_ON_NODE_CUMULATIVE
#ifdef COLOR_DECREASE_LINE_CUMULATIVE
	__global__ void selectStarColoringDecreaseLine_cumulative(uint32_t nnodes, uint32_t * starColoring_d, float * qStar_d, col_sz nCol, uint32_t * coloring_d, node_sz * cumulDegs, node * neighs, bool * colorsChecker_d, float * probDistribution_d, curandState * states, float epsilon, uint32_t * statsFreeColors_d);
#endif // COLOR_DECREASE_LINE_CUMULATIVE

	__global__ void lookOldColoring(uint32_t nnodes, float * q_d, col_sz nCol, uint32_t * starColoring_d, uint32_t * coloring_d, node_sz * cumulDegs, node * neighs, bool * colorsChecker_d, float epsilon);
}
