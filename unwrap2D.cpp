// mex wrapper to https://github.com/geggo/phase-unwrap

// includes, system
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <iostream>

// MATLAB related
#include "mex.h"
#include "mxShowCriticalErrorMessage.c"

// unwrap2D c code
#include "unwrap2D.c"

// gateway to MATLAB
void mexFunction(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    if(nrhs < 1 || nrhs > 2)
        mxShowCriticalErrorMessage("wrong number of input arguments",nrhs);
    
    if(nlhs > 1)
        mxShowCriticalErrorMessage("wrong number of output arguments",nlhs);
    
    if(mxIsComplex(prhs[0]) || !mxIsClass(prhs[0],"single"))
        mxShowCriticalErrorMessage("argument 1 must be single real");
    
    int ndims = mxGetNumberOfDimensions(prhs[0]);
    
    if(ndims != 2)
        mxShowCriticalErrorMessage("argument 1 must be a 2D image");
    
    const size_t *dims = mxGetDimensions(prhs[0]);
    int nx = dims[0], ny = dims[1];
    
    if(nx == 1 || ny == 1)
        mxShowCriticalErrorMessage("argument 1 must be a 2D image");
    
    // mask (need to use unsigned char): 0=keep 1=reject
    unsigned char* input_mask = (unsigned char*) calloc(nx*ny,sizeof(unsigned char));
    
    if (nrhs==2)
    {
        if(mxGetNumberOfDimensions(prhs[1]) != 2)
            mxShowCriticalErrorMessage("argument 2 must be a 2D image");
        
        dims = mxGetDimensions(prhs[1]);
        if(dims[0] != nx || dims[1] != ny)
            mxShowCriticalErrorMessage("argument 1 and 2 must be same size");
        
        if(mxIsComplex(prhs[1]))
            mxShowCriticalErrorMessage("argument 2 must be real");
        
        // handle all numeric types: 1 bit, 8 bit, 16 bit, 32 bit, 64 bit
        switch(mxGetClassID(prhs[1]))
        {
            case mxLOGICAL_CLASS: for (int i = 0; i<nx*ny; i++) input_mask[i] = ((bool*)mxGetData(prhs[1]))[i] == 0;
            break;
            
            case mxCHAR_CLASS:
            case mxINT8_CLASS:
            case mxUINT8_CLASS: for (int i = 0; i<nx*ny; i++) input_mask[i] = ((int8_t*)mxGetData(prhs[1]))[i] == 0;
            break;
            
            case mxINT16_CLASS:
            case mxUINT16_CLASS: for (int i = 0; i<nx*ny; i++) input_mask[i] = ((int16_t*)mxGetData(prhs[1]))[i] == 0;
            break;
            
            case mxINT32_CLASS:
            case mxUINT32_CLASS:
            case mxSINGLE_CLASS: for (int i = 0; i<nx*ny; i++) input_mask[i] = ((int32_t*)mxGetData(prhs[1]))[i] == 0;
            break;
            
            case mxINT64_CLASS:
            case mxUINT64_CLASS:
            case mxDOUBLE_CLASS: for (int i = 0; i<nx*ny; i++) input_mask[i] = ((int64_t*)mxGetData(prhs[1]))[i] == 0;
            break;
            
            default: mxShowCriticalErrorMessage("argument 2 type not compatible");
        }
        
        // check mask
        int nnz = 0;
        for (int i = 0; i<nx*ny; i++) nnz += input_mask[i] == 0;
        if(nnz==0) mxShowCriticalErrorMessage("mask cannot be all zero");
        
    }
    
    // output array
    plhs[0] = mxCreateNumericArray(ndims, dims, mxSINGLE_CLASS, mxREAL);
    
    // send it to the c function
    float* wrapped_image = (float*)mxGetData(prhs[0]);
    float* unwrapped_image = (float*)mxGetData(plhs[0]);
    int image_width = nx;
    int image_height = ny;
    int wrap_around_x = 0; // circular wrap in x
    int wrap_around_y = 0; // circular wrap in y

    unwrap2D(wrapped_image, unwrapped_image, input_mask,
            image_width, image_height,
            wrap_around_x, wrap_around_y);
    
    free(input_mask);
    
}
