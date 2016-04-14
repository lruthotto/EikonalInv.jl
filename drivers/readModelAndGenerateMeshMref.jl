function readModelAndGenerateMeshMref(readModelFolder::ASCIIString,modelFilename::ASCIIString,dim::Int64,pad::Int64,newSize::Vector,domain::Vector)


if dim==2
	# SEGmodel2Deasy.dat
	m = readdlm(string(readModelFolder,"/",modelFilename));
	m = m*1e-3;
	m = m';
	m = (1./m).^2;
	mref = getSimilarLinearModel(m);
else
	# 3D SEG slowness model
	# modelFilename = 3Dseg256256128.mat
	file = matopen(string(readModelFolder,"/",modelFilename)); DICT = read(file); close(file);
	m = DICT["VELs"];
	m = m*1e-3;
	m = (1./m).^2;	
	mref = getSimilarLinearModel(m);
end

sea = abs(m[:] .- maximum(m)) .< 1e-2;
mref[sea] = m[sea];
if newSize!=[]
	m    = expandModelNearest(m,   collect(size(m)),newSize);
	mref = expandModelNearest(mref,collect(size(m)),newSize);
end
Minv = getRegularMesh(domain,collect(size(m))-1);


(mPadded,MinvPadded) = addAbsorbingLayer(m,Minv,pad);
(mrefPadded,MinvPadded) = addAbsorbingLayer(mref,Minv,pad);



N = prod(MinvPadded.n+1);
boundsLow  = 0.99*minimum(mPadded);
boundsHigh = 1.01*maximum(mPadded);

boundsLow  = ones(N)*boundsLow;
boundsLow = convert(Array{Float32},boundsLow);
boundsHigh = ones(N)*boundsHigh;
boundsHigh = convert(Array{Float32},boundsHigh);

return (mPadded,MinvPadded,mrefPadded,boundsHigh,boundsLow);
end