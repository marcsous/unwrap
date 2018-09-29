function output = unwrap3(varargin)
%
%Phase unwrapping in 3D using mex wrapper to
%code at https://github.com/geggo/phase-unwrap
%
%output = unwrap3(input)
%output = unwrap3(input,mask)
%
%Inputs
%-input: wrapped phase between -pi and pi
%-mask: binary quality mask (1=keep 0=reject)
%
%Outputs
%-output: unwrapped phase


output = unwrap3(varargin{:});
