classdef nufft_3d

    properties (SetAccess = immutable)
        
        J      @double scalar  = 4;  % kernel width (4)
        u      @double scalar  = 2;  % oversampling factor (2)
        N      @double = zeros(3,1); % final matrix dimensions       
        K      @double = zeros(3,1); % oversampled matrix dimensions
        alpha  @double scalar  = 0;  % kaiser-bessel parameter (0=Fessler optimal)
        radial @logical scalar = 1;  % radial kernel (1=yes 0=no)
        deap   @logical scalar = 0;  % deapodization type (0=analytical 1=numerical)
        gpu    @logical scalar = 1;  % use gpuSparse instead of sparse (1=yes 0=no)

        H;                           % sparse interpolation matrix
        HT;                          % transpose of H (faster if stored separately)
        U;                           % deapodization matrix
        d;                           % density weighting vector

    end

    methods
        
        %% Constructor
        function obj = nufft_3d(om,N,varargin)
            
            % Non-uniform fourier transform (based on Fessler NUFFT).
            %
            % Inputs:
            %  om = trajectory centered at (0 0 0) units 1/fov [3 npts]
            %  N = final matrix dimensions (must be even number) [3 1]
            %  varargin = string/value pairs, e.g. ('J',5)
            %
            % Output:
            %  obj = nufft object using sparse matrix coeffficients
            %
            if nargin==0
                return; % 0 arg option needed for class constructor
            end 
            if ~isnumeric(om) || isempty(om) || size(om,1)~=3
                error('om must be an array with leading dimension of 3')
            end
            if ~exist('N','var') || isempty(N) || ~isnumeric(N)
                N = 2 * ceil(max(max(abs(om),[],2),[],3));
                warning('N argument not valid. Using [%i %i %i].',N)
            end

            % varargin handling - must be field/value pairs, e.g. ('J',5)
            for k = 1:2:numel(varargin)
                if k==numel(varargin) || ~ischar(varargin{k})
                    error('''varargin'' must be supplied in string/value pairs.');
                end
                obj.(varargin{k}) = varargin{k+1};
            end
            
            %% check values, sizes, shapes, etc.
            if obj.J<1 || obj.J>6
                error('value of J=%f is not recommended',obj.J);
            end
            if obj.u<1 || obj.u>4
                error('value of u=%f is not recommended',obj.u);
            end
            if obj.alpha==0 
                obj.alpha = obj.J * spline([1 1.5 2 3],[1.5 2.05 2.34 2.6],obj.u);
            end
            if obj.radial && obj.u~=2
                warning('radial kernel not tested with u=%f (try u=2).',obj.u)
            end
            if numel(N)==1 || numel(N)==3
                obj.N = ones(1,3).*reshape(N,1,[]); N = [];
            else
                error('N argument must be scalar or 3-vector.')
            end
            om = reshape(om,3,[]);
            
            % odd matrix sizes not tested - probably won't work
            if any(mod(obj.N,2))
                error('matrix size must be even - not tested with odd values.')
            end
            
            % oversampled matrix size (must be even)
            obj.K = 2 * ceil(obj.N * obj.u / 2);

            % display trajectory limits
            disp(' Trajectory:     min        max        matrix')
            fprintf('   om(1):    %.3f       %.3f      %i\n',min(om(1,:)),max(om(1,:)),obj.N(1))
            fprintf('   om(2):    %.3f       %.3f      %i\n',min(om(2,:)),max(om(2,:)),obj.N(2))           
            fprintf('   om(3):    %.3f       %.3f      %i\n',min(om(3,:)),max(om(3,:)),obj.N(3))
            
            % convert trajectory to new units (double to avoid precision loss in H)
            kx = obj.u * double(om(1,:));
            ky = obj.u * double(om(2,:));
            kz = obj.u * double(om(3,:));
           
            % only keep points that are within bounds
            ok = abs(kx<obj.K(1)/2) & abs(ky<obj.K(2)/2) & abs(kz<obj.K(3)/2);
            fprintf('  %i points (out of %i) are out of bounds.\n',sum(~ok),numel(ok))


            %% set up indicies and convolution coefficients
            
            % no. columns
            ncol = prod(obj.K);
            
            % no. rows
            nrow = numel(ok);
            
            % interpolation matrix: because H and H' have wildly
            % different performance, store them both and always
            % use the fastest operation. Cost = 2x memory.
            %
            % on CPU
            %  -transpose is faster to create due to sorted columns
            %  -transpose is faster to multiply (H'*y >> HT*y)
            % on GPU
            %  -non-transpose is faster to create due to sorted rows
            %  -non-tranpose is faster to multiply (HT*y >> H'*y)
            %
            obj.H  = sparse(nrow,ncol);
            obj.HT = sparse(ncol,nrow);
            obj.U = zeros(obj.N,'single'); % deapodization matrix
            
            % push to gpu if needed (try/catch fallback to cpu)
            if obj.gpu
                try
                    obj.H  = gpuSparse(obj.H);
                    obj.HT = gpuSparse(obj.HT);
                    obj.U = gpuArray(obj.U);
                    kx = gpuArray(kx);
                    ky = gpuArray(ky);
                    kz = gpuArray(kz);
                    ok = gpuArray(ok);
                catch ME
                    obj.gpu = 0;
                    warning('%s Setting gpu=0.',ME.message);
                end
            end
           
            tic; fprintf(' Creating sparse matrix H     ');

            for ix = 1:ceil(obj.J)
                for iy = 1:ceil(obj.J)
                    for iz = 1:ceil(obj.J)
                        
                        % neighboring grid points: keep ix,iy,iz outside floor() to avoid problems
                        x = floor(kx-obj.J/2) + ix;
                        y = floor(ky-obj.J/2) + iy;
                        z = floor(kz-obj.J/2) + iz;
                        
                        % Euclidian distance (squared) for the samples
                        dx2 = (x-kx).^2;
                        dy2 = (y-ky).^2;
                        dz2 = (z-kz).^2;
                        dist2 = dx2 + dy2 + dz2;
                        
                        % Euclidian distance (squared) for numerical deapodisation
                        ux2 = (ix-1).^2/4;
                        uy2 = (iy-1).^2/4;
                        uz2 = (iz-1).^2/4;
                        udist2 = ux2 + uy2 + uz2;
                        
                        % wrap out of bounds
                        x = mod(x,obj.K(1));
                        y = mod(y,obj.K(2));
                        z = mod(z,obj.K(3));

                        % sparse matrix indices
                        if obj.radial
                            % radial kernel
                            i = find(ok & dist2 < obj.J.^2/4);
                            j = 1+x(i) + obj.K(1)*y(i) + obj.K(1)*obj.K(2)*z(i);
                            s = obj.convkernel(dist2(i));
                            % deapodization coefficients
                            if obj.deap && udist2 <= obj.J.^2/4
                                obj.U(ix,iy,iz) = obj.convkernel(udist2);
                            end
                        else
                            % separable kernel
                            i = find(ok & dx2<obj.J.^2/4 & dy2<obj.J.^2/4 & dz2<obj.J.^2/4);
                            j = 1+x(i) + obj.K(1)*y(i) + obj.K(1)*obj.K(2)*z(i);
                            s = obj.convkernel(dx2(i)).*obj.convkernel(dy2(i)).*obj.convkernel(dz2(i));
                            % deapodization coefficients
                            if obj.deap && ux2<=obj.J.^2/4 && uy2<=obj.J.^2/4 && uz2<=obj.J.^2/4
                                obj.U(ix,iy,iz) = obj.convkernel(ux2).*obj.convkernel(uy2).*obj.convkernel(uz2);
                            end
                        end

                        % accumulate sparse matrix
                        if obj.gpu
                            i = int32(i); j = int32(j); s = single(s);
                            obj.H = obj.H + gpuSparse(i,j,s,nrow,ncol);
                        else
                            obj.HT = obj.HT + sparse(j,i,s,ncol,nrow);
                        end
                        
                        % display progress
                        fprintf('\b\b\b\b%-2d%% ',floor(100*sub2ind(ceil([obj.J obj.J obj.J]),iz,iy,ix)/ceil(obj.J).^3));
                    end
                end
            end
            fprintf('\b. '); toc

            % free memory for GPU
            clear dist2 dx2 dy2 dz2 kx ky kz x y z i j k s
            
            % un-transpose
            tic; fprintf(' Un-transposing sparse matrix. ');
            
            if obj.gpu
                try
                    obj.HT = full_ctranspose(obj.H);
                catch ME % out of memory?
                    obj.HT = obj.H';
                    warning('Using lazy transpose. %s',ME.message);
                end
            else
                obj.H = obj.HT';
            end
            toc

            % deapodization matrix
            tic; fprintf(' Creating deapodization function. ');

            if obj.deap
                
                % numerical deapodization (with 2x oversampling)
                for j = 1:3
                    obj.U = ifft(obj.U*obj.K(j),2*obj.K(j),j,'symmetric');
                    if j==1; obj.U(1+N(1)/2:end-N(1)/2,:,:) = []; end
                    if j==2; obj.U(:,1+N(2)/2:end-N(2)/2,:) = []; end
                    if j==3; obj.U(:,:,1+N(3)/2:end-N(3)/2) = []; end
                end
                obj.U = fftshift(obj.U);

            else
                
                % analytical deapodization (Lewitt, J Opt Soc Am A 1990;7:1834)
                if false
                    % centered: do not use, requires centered fftshifts, no advantage in accuracy
                    x = ((1:obj.N(1))-obj.N(1)/2-0.5)./obj.K(1);
                    y = ((1:obj.N(2))-obj.N(2)/2-0.5)./obj.K(2);
                    z = ((1:obj.N(3))-obj.N(3)/2-0.5)./obj.K(3);
                else
                    % not centered: gives almost the same deapodization matrix as numerical
                    x = ((1:obj.N(1))-obj.N(1)/2-1)./obj.K(1);
                    y = ((1:obj.N(2))-obj.N(2)/2-1)./obj.K(2);
                    z = ((1:obj.N(3))-obj.N(3)/2-1)./obj.K(3);
                end
                [x y z] = ndgrid(x,y,z);

                if obj.radial
                    % radial
                    a = obj.J/2;
                    C = 4*pi*a.^3/obj.bessi0(obj.alpha);
                    R = realsqrt(x.^2 + y.^2 + z.^2);
                    
                    k = 2*pi*a*R < obj.alpha;
                    sigma = realsqrt(obj.alpha.^2 - (2*pi*a*R(k)).^2);
                    obj.U(k) = C * (cosh(sigma)./sigma.^2 - sinh(sigma)./sigma.^3);
                    sigma = realsqrt((2*pi*a*R(~k)).^2 - obj.alpha.^2);
                    obj.U(~k) = C * (sin(sigma)./sigma.^3 - cos(sigma)./sigma.^2);
                else
                    % separable
                    a = obj.J/2;
                    C = 2*a/obj.bessi0(obj.alpha);
                    
                    k = 2*pi*a*abs(x) < obj.alpha;
                    sigma = realsqrt(obj.alpha.^2 - (2*pi*a*x(k)).^2);
                    obj.U(k) = C * (sinh(sigma)./sigma);
                    sigma = realsqrt((2*pi*a*x(~k)).^2 - obj.alpha.^2);
                    obj.U(~k) = C * (sin(sigma)./sigma);
                    
                    k = 2*pi*a*abs(y) < obj.alpha;
                    sigma = realsqrt(obj.alpha.^2 - (2*pi*a*y(k)).^2);
                    obj.U(k) = C * (sinh(sigma)./sigma) .* obj.U(k);
                    sigma = realsqrt((2*pi*a*y(~k)).^2 - obj.alpha.^2);
                    obj.U(~k) = C * (sin(sigma)./sigma) .* obj.U(~k);
                    
                    k = 2*pi*a*abs(z) < obj.alpha;
                    sigma = realsqrt(obj.alpha.^2 - (2*pi*a*z(k)).^2);
                    obj.U(k) = C * (sinh(sigma)./sigma) .* obj.U(k);
                    sigma = realsqrt((2*pi*a*z(~k)).^2 - obj.alpha.^2);
                    obj.U(~k) = C * (sin(sigma)./sigma) .* obj.U(~k);
                end
                
            end
            toc

            % turn into a deconvolution (catch div by zero)
            obj.U = 1 ./ hypot(obj.U, eps);
            if obj.gpu; obj.U = gpuArray(obj.U); end

            % we are going to do a lot of ffts of the same size so tune it
            fftw('planner','measure');

            % calculate density weighting
            obj.d = obj.density(ok);

            % display properties
            fprintf(' Created'); disp(obj);
            w = whos('obj');
            fprintf('\n')
            fprintf('\t H: [%ix%i] (nonzeros %i) %0.1fMbytes\n',size(obj.H),nnz(obj.H),w.bytes/1e6);
            fprintf('\tHT: [%ix%i] (nonzeros %i) %0.1fMbytes\n',size(obj.HT),nnz(obj.HT),w.bytes/1e6);
            fprintf('\t U: [%ix%ix%i] min=%f max=%f\n',size(obj.U),min(obj.U(:)),max(obj.U(:)))
            fprintf('\t d: [%ix%i] (zeros %i) min=%f max=%f\n',size(obj.d),nnz(~obj.d),min(obj.d(~~obj.d)),max(obj.d))
            fprintf('\n')
  
        end
        
        %% utility functions
        
        % sparse matrix vector multiply (keep all the hacks in one place)
        function y = spmv(obj,k)
            if obj.gpu
                y = single(k);
                y = obj.H * y;
            else
                y = double(k);
                y = obj.HT' * y;
                y = full(y);
                y = single(y);
            end
        end
        
        % sparse transpose matrix vector multiply (keep all the hacks in one place)
        function y = spmv_t(obj,k)
            if obj.gpu
                y = single(k);
                y = obj.HT * y;
            else
                y = double(k);
                y = obj.H' * y;
                y = full(y);
                y = single(y);
            end
        end
        
        % 3d fft with pre-fft padding (cartesian kspace <- cartesian image)
        function k = fft3_pad(obj,k)
            for j = 1:3
                pad = (obj.K(j) - obj.N(j)) / 2;
                if j==1; k = padarray(k,[pad 0 0]); end
                if j==2; k = padarray(k,[0 pad 0]); end
                if j==3; k = padarray(k,[0 0 pad]); end
                k = fft(fftshift(k,j),[],j);
            end
        end

        % 3d ifft with post-ifft cropping (cartesian image <- cartesian kspace)
        function x = ifft3_crop(obj,x)
            for j = 1:3
                scale = obj.K(j) / obj.N(j); % undo ifft scaling and reapply with correct size
                crop = (obj.K(j) - obj.N(j)) / 2;
                x = ifftshift(ifft(x,[],j),j).*scale;
                if j==1; x = x(1+crop:end-crop,:,:); end
                if j==2; x = x(:,1+crop:end-crop,:); end
                if j==3; x = x(:,:,1+crop:end-crop); end
            end
        end

        % forward non-uniform FT (irregular kspace <- cartesian image)
        function k = fNUFT(obj,x)
            % k = A * x
            k = reshape(x,obj.N);
            k = k.*obj.U;
            k = obj.fft3_pad(k);
            k = reshape(k,[],1);
            k = obj.spmv(k);
        end
        
        % adjoint non-uniform FT (cartesian image <- irregular kspace)
        function x = aNUFT(obj,k)
            % x = A' * k
            x = reshape(k,[],1);
            x = obj.spmv_t(x);
            x = reshape(x,obj.K);
            x = obj.ifft3_crop(x);
            x = x.*obj.U;
        end
        
        % image projection operator (image <- image)
        function y = iprojection(obj,x,damping,W)
            % y = A' * W * D * W * A * x
            y = obj.fNUFT(x);
            y = (W.*obj.d).*y; % density weighting included
            y = obj.aNUFT(y);
            y = reshape(y,size(x));
            if ~isscalar(damping)
                damping = reshape(damping,size(x));
            end
            y = y + damping.^2.*x;
        end

        % phase constrained projection operator (image <- image)
        function y = pprojection(obj,x,damping,phase_constraint,W,P)
            % y = P' * A' * W * D * W * A * P * x + penalty on imag(x)
            P = reshape(P,size(x));
            y = P.*x;
            y = obj.iprojection(y,damping,W);
            if ~isscalar(phase_constraint)
                phase_constraint = reshape(phase_constraint,size(x));
            end
            y = conj(P).*y + i.*phase_constraint.*imag(x);
        end

        % replacement for matlab besseli function (from Numerical Recipes in C)
        function ans = bessi0(obj,ax)
            ans = zeros(size(ax),'like',ax);
            
            % ax<3.75
            k=ax<3.75;
            y=ax(k)./3.75;
            y=y.^2;
            ans(k)=1.0+y.*(3.5156229+y.*(3.0899424+y.*(1.2067492+...
                   y.*(0.2659732+y.*(0.360768e-1+y.*0.45813e-2)))));
 
            % ax>=3.75
            k=~k;
            y=3.75./ax(k);
            ans(k)=(exp(ax(k))./realsqrt(ax(k))).*(0.39894228+y.*(0.1328592e-1+...
                   y.*(0.225319e-2+y.*(-0.157565e-2+y.*(0.916281e-2+y.*(-0.2057706e-1+...
                   y.*(0.2635537e-1+y.*(-0.1647633e-1+y.*0.392377e-2))))))));
        end
        
        % convolution kernel (no error checking, out of bounds will cause an error)
        function s = convkernel(obj,dist2)
            s = obj.bessi0(obj.alpha*realsqrt(1-dist2/(obj.J/2).^2)) / obj.bessi0(obj.alpha);
            %s = besseli(0,obj.alpha*realsqrt(1-dist2/(obj.J/2).^2)) / besseli(0,obj.alpha);
        end
        
        % use with svds/eigs to calculate singular values of projection operator
        function y = svds_func(obj,x,tflag)
            damping = 0; W = 1;
            if obj.gpu; x = gpuArray(x); end
            y = obj.iprojection(x,damping,W);
            if obj.gpu; y = gather(y); end
        end
        
        %% density estimation
        function d = density(obj,ok)

            % Pipe's method 
            maxit = 10;
            fprintf(' Calculating density. '); tic

            % initial estimate (preserve zeros = out of bounds)
            d = reshape(ok,[],1);

            % iterative refinement
            for j = 1:maxit
                q = obj.spmv(obj.spmv_t(d));
                d = d ./ hypot(q, eps); % prevent div by zero
            end
            
            % scale so regridding gives similar result to least squares: not working
            if false
                % s = max sval of A'DA: should be 1 if d is scaled correctly
                opts = struct('issym',1,'isreal',0,'tol',1e-3);
                s = eigs(@obj.svds_func, prod(obj.N), 1, 'lm', opts);
            else
                % s = norm of diag(d): not correct but fast
                s = max(d);
            end
            d = d ./ s;
            toc

        end
        
        %% inverse non-uniform FT (cartesian image <- irregular kspace)
        function im = iNUFT(obj,raw,tol,maxit,damping,phase_constraint,W)
            
            % raw = complex raw data [npts nc ne] or [nr ny nc ne]
            % maxit [scalar] = no. iterations (0=poorly scaled regridding 1=well-scaled regridding)
            % tol [scalar] = tolerance (tol=0 allows early termination, only applies when maxit>1)
            % damping [scalar] = Tikhonov regularization term (only applies when maxit>1)
            % phase_constraint [scalar] = phase constraint term (only applies when maxit>1)
            % W [scalar, ny or nr*ny] = data weighting (only applies when maxit>1)

            % no. data points
            nrow = size(obj.H,1);
            
            % size checks
            if size(raw,1)==nrow
                nc = size(raw,2);
                nte = size(raw,3);
                fprintf('  %s received raw data: npts=%i nc=%i ne=%i\n',mfilename,nrow,nc,nte);
            else
                nr = size(raw,1); % assume readout points
                ny = size(raw,2); % assume no. of spokes
                if nr*ny ~= nrow
                    error('raw data leading dimension(s) must be length %i (not %ix%i).',nrow,nr,ny)
                end
                nc = size(raw,3);
                nte = size(raw,4);
                fprintf('  %s received raw data: nr=%i ny=%i nc=%i ne=%i.\n',mfilename,nr,ny,nc,nte);
            end
            raw = reshape(raw,nrow,nc,nte);

            % optional argument checks
            if ~exist('maxit','var') || isempty(maxit)
                maxit = 1;
            else
                validateattributes(maxit,{'numeric'},{'scalar','finite','integer','nonnegative'},'','maxit');
            end
            if ~exist('tol','var') || isempty(tol)
                tol = [];
            else
                validateattributes(tol,{'numeric'},{'scalar','finite','nonnegative'},'','tol');
            end
            if ~exist('damping','var') || isempty(damping)
                damping = 0;
            else
                validateattributes(damping,{'numeric'},{'scalar','finite','nonnegative'},'','damping');
            end
            if ~exist('phase_constraint','var') || isempty(phase_constraint)
                phase_constraint = 0;
            else
                validateattributes(phase_constraint,{'numeric'},{'scalar','finite','nonnegative'},'','phase_constraint');
            end
            if ~exist('W','var') || isempty(W)
                W = 1;
            else
                if numel(W)~=nrow
                    if ~exist('ny','var')
                        % guess - expect W to be vector of length ny
                        ny = numel(W);
                        nr = nrow/ny;
                    end
                    % this should catch most size mismatches
                    if mod(nr,1) || nr*ny~=nrow || isscalar(W)
                        error('W must be a vector of length ny or ny*nr.');
                    end
                    W = repmat(reshape(W,1,ny),nr,1);
                end
                W = reshape(W,nrow,1);
                if numel(unique(W))==1; W = W(1); end
                if ~any(W); error('W cannot be all zero.'); end
                validateattributes(W,{'numeric','gpuArray'},{'finite','nonnegative'},'','W');
            end

            % damping, weighting and phase_constraint require iterative recon
            if ~isempty(tol) && maxit<=1
                error('tol is only active when maxit>1.');
            end
            if damping~=0 && maxit<=1
                error('damping is only active when maxit>1.');
            end
            if ~isscalar(W) && maxit<=1
                error('weighting is only active when maxit>1.');
            end
            if phase_constraint~=0 && maxit<=1
                error('phase constraint is only active when maxit>1.');
            end

			% display
            fprintf('  maxit=%i tol=%.1e damping=%.1e ',maxit,tol,damping);
			fprintf('phase_constraint=%.1e weighted=%i\n',phase_constraint,~isscalar(W));

 			% experimental method to inhibit noise amplification at edges of image
 			damping = damping * obj.U / min(obj.U(:));

            %  push to gpu if needed
            if obj.gpu
                W = gpuArray(W);
                damping = gpuArray(damping);
                phase_constraint = gpuArray(phase_constraint);
            end

            % array for the final images
            im = zeros([size(obj.U) nc nte],'single');

            % reconstruction. note: don't use parfor in these loops, it is REALLY slow
            tic
            for e = 1:nte
                for c = 1:nc

                    if maxit==0 || phase_constraint
                        
                        % regridding x = (A'Db). hard to scale correctly, prefer pcg with 1 iteration
                        x = obj.aNUFT(obj.d.*raw(:,c,e));
                        
                    else

                        % least squares (A'WDA)(x) = (A'Db)
                        b = obj.aNUFT((W.*obj.d).*raw(:,c,e));
                        
                        % correct form for solver
                        b = reshape(b,[],1);
                        
                        [x,~,relres,iter] = pcgpc(@(x)obj.iprojection(x,damping,W),b,tol,maxit);
                        %fprintf('  pcg finished at iteration=%i with relres=%.3e\n',iter,relres);
                        
                    end
                   
                    % phase constrained: need to use pcgpc (real dot products) instead of pcg
                    if phase_constraint

					    % use non-constrained estimate for low-resolution phase
                        x = reshape(x,size(obj.U));

                        % smooth in image space so voxel size is independent of osf
                        h = hamming(11);
                        P = fftshift(x); % shift center to mitigate edge effects
                        P = convn(P,reshape(h,numel(h),1,1),'same');
                        P = convn(P,reshape(h,1,numel(h),1),'same');
                        P = convn(P,reshape(h,1,1,numel(h)),'same');
                        P = ifftshift(P); % shift center back to origin
                        P = exp(i*angle(P));

                        % RHS vector
                        b = conj(P).*obj.aNUFT((W.*obj.d).*raw(:,c,e));

                        % correct form for solver
                        P = reshape(P,[],1);
                        b = reshape(b,[],1);

                        % phase constrained (P'A'WDAP)(P'x) = (P'A'WDb) with penalty on imag(P'x)
                        % (REF: Bydder & Robson, Magnetic Resonance in Medicine 2005;53:1393)
                        [x,~,relres,iter] = pcgpc(@(x)obj.pprojection(x,damping,phase_constraint,W,P),b,tol,maxit);
                        %fprintf('  pcg finished at iteration=%i with relres=%.3e\n',iter,relres);
                        
                        % put back the low resolution phase
                        x = P.*x;

                    end
                    
                    % reshape into image format
                    im(:,:,:,c,e) = reshape(gather(x),size(obj.U));

                end
            end
            fprintf('  %s returned %ix%ix%ix%i dataset. ',mfilename,size(im(:,:,:,1)),size(im(1,1,1,:),4)); toc

        end
        
    end
    
end

