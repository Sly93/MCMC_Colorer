#include <coloring.h>
#include <coloringGreedyFF.h>
#include <graph/graph.h>

#include "GPUutils/GPUutils.h"          //is required in order to use cudaCheck

#include <thrust/find.h>                //is used for finding the first occurence
#include <set>                          //is used for counting the number of colors
#include <thrust/count.h>               //is used for conversion to standard notation
#include <thrust/scan.h>


template<typename nodeW, typename edgeW>
ColoringGreedyFF<nodeW, edgeW>::ColoringGreedyFF(Graph<nodew, edgew>* graph_d) :
    Colorer<nodeW, edgeW>(graph_d), graphStruct_device(graph_d->getStruct()),
    numNodes(graph_d->getStruct()->nNodes), numColors(0), coloredNodesCount(0) {
    
    //coloring_host = std::unique_ptr<int[]>(new int[numNodes]);
    coloring_host = thrust::host_vector<uint32_t>(numNodes);
    coloring_device = thrust::device_vector<uint32_t>(numNodes, 0);
    //We need to have an array representing the colors of each node
//  cudaStatus = cudaMalloc((void**)&coloring_device, numNodes * sizeof(uint32_t));     cudaCheck(cudaStatus, __FILE__, __LINE__);
//  cudaStatus = cudaMalloc((void**)&numColors_device, sizeof(uint32_t));               cudaCheck(cudaStatus, __FILE__, __LINE__);
    
    //We setup our grid to be divided in blocks of 128 threads 
    threadsPerBlock = dim3(128, 1, 1);
    blocksPerGrid = dim3((numNodes + threadsPerBlock.x - 1)/threadsPerBlock.x, 1, 1);
}

template<typename nodeW, typename edgeW>
ColoringGreedyFF<nodeW, edgeW>::~ColoringGreedyFF(){
    //We only need to deallocate what we allocated in the constructor
//  cudaStatus = cudaFree(coloring_device);     cudaCheck(cudaStatus, __FILE__, __LINE__);
    
    if(coloring != nullptr)                 //NOTE: this may be unnecessary
        free(coloring);
}

template<typename nodeW, typename edgeW>
void ColoringGreedyFF<nodew, edgeW>::run(){

//  cudaStatus = cudaMemset(coloring_device, 0, numNodes * sizeof(uint32_t));           cudaCheck(cudaStatus, __FILE__, __LINE__); 
    
    uint32_t maxColors = graph->getMaxNodeDeg() + 1;                    //We are assuming getMaxNodeDeg() returns a valid result here
    thrust::device_vector<uint32_t> temp_coloring(coloring_device);
    thrust::device_vector<uint32_t>::iterator firstUncolored = coloring_device.begin();
    while(firstUncolored != coloring_device.end()){
        
        //Tentative coloring on the whole graph, in parallel
        tentative_coloring<<<blocksPerGrid, threadsPerBlock>>>(numNodes, coloring_device, temp_coloring, graphStruct_device->cumulDegs, graphStruct_device->neighs, maxColors);
        cudaDeviceSynchronize();

        //Update the coloring now that we are sure there is no conflict
        coloring_device = temp_coloring;
        cudaDeviceSynchronize();

        //Checking for conflicts and letting lower nodes win over the others, in parallel
        conflict_detection<<<blocksPerGrid, threadsPerBlock>>>(numNodes, coloring_device, temp_coloring, graphStruct_device->cumulDegs, graphStruct_device->neighs, maxColors);
        cudaDeviceSynchronize();

        //Update the coloring before next loop
        coloring_device = temp_coloring;
        cudaDeviceSynchronize();

        firstUncolored = thrust::find(coloring_device.begin(), coloring_device.end(), 0);
    }

    coloring_host = coloring_device;
    cudaDeviceSynchronize();
    std::set color_set(coloring_host.begin(), coloring_host.end());
    numColors = color_set.size();
    convert_to_standard_notation();
}

template<typename nodeW, typename edgeW>
__global__ void ColoringGreedyFF<nodeW, edgeW>::tentative_coloring(const uint32_t numNodes, thrust::device_vector<uint32_t> input_coloring, thrust::device_vector<uint32_t> output_coloring, const node_sz * const cumulDegs, const node * const neighs, const uint32_t maxColors){
    uint32_t idx = threadIdx.x + blockIdx.x * blockDim.x;

    //If idx doesn't correspond to a node, it is excluded from this computation
    if(idx >= numNodes){     
        return;
    }
    //If the idx-th node has already been colored, it is excluded from this computation
    if(input_coloring[idx] != 0){
        return;
    }
    
    thrust::device_vector<uint32_t> forbiddenColors = thrust::device_vector<uint32_t>(maxColors, 0); 
    uint32_t numNeighs = cumulDegs[idx+1] - cumulDegs[idx];
    uint32_t neighsOffset = cumulDegs[idx];
    uint32_t neighbor;

    for(uint32_t j = 0; j < numNeighs; ++j){
        neighbor = neighs[j];
        forbiddenColors[input_coloring[neighbor]] = idx;
    }
    
    for(uint32_t i = 1; i < maxColors; ++i){
        if(forbiddenColors[i] != idx){
            output_coloring[idx] = i;
            break;
        }
    }
}

template<typename nodeW, typename edgeW>
__global__ void ColoringGreedyFF<nodeW, edgeW>::conflict_detection(const uint32_t numNodes, thrust::device_vector<uint32_t> input_coloring, thrust::device_vector<uint32_t> output_coloring, const node_sz * const cumulDegs, const node * const neighs, const uint32_t maxColors){
    uint32_t idx = threadIdx.x + blockIdx.x * blockDim.x;

    //If idx doesn't correspond to a node, it is excluded from this computation
    if(idx >= numNodes){
        return;
    }

    //If the idx-th node has no color, it is excluded from this computation
    //  NOTE: this should not happen
    if(input_coloring[idx] == 0){
        return;
    }

    uint32_t numNeighs = cumulDegs[idx+1] - cumulDegs[idx];
    uint32_t neighsOffset = cumulDegs[idx];
    uint32_t neighbor;

    //   If the idx-th node has the same color of a neighbor 
    //  and its id is greater than the one of its neighbor
    //  we make it uncolored
    for(uint32_t j = 0; j < numNeighs; ++j){
        neighbor = neighs[neighsOffset + j];
        if(input_coloring[idx] == input_coloring[neighbor] && idx > neighbor){
            output_coloring[idx] = 0;
            break;
        }
    }
}

//   This method is implemented without testing coloring correctness
//  by translating what was already done in coloringLuby.cu and without
//  filling a Coloring on device
template<typename nodeW, typename edgeW>
void ColoringGreedyFF<nodeW, edgeW>::convert_to_standard_notation(){

    //   Since we already use 0 as an "uncolored" identifier, there's no need to do
    //  what coloringLuby.cu does on lines colClass (lines 93-to-103, see NB on line 95) 
    
    uint32_t *cumulColorClassesSize = new uint32_t[numColors + 1];
    memset(cumulColorClassesSize, 0, (numColors+1)*sizeof(uint32_t));

    //Count how many nodes are colored with <col> and store them in the array, before...
    for(uint32_t col = 1; col < numColors + 1; ++col){
        cumulColorClassesSize[col] = thrust::count(coloring_host.begin(), coloring_host.end(), col);
    }
    
    //... you accumulate them in place
    thrust::inclusive_scan(cumulColorClassesSize, cumulColorClassesSize + (numColors + 1), cumulColorClassesSize); 

    coloring = new Coloring();
    coloring->nCol = numColors;
    coloring->colClass = thrust::raw_pointer_cast(coloring_host.data());
    coloring->cumulSize = cumulColorClassesSize;
}