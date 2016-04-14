function invertTravelTimeTomography(m,filenamePrefix::ASCIIString, resultsOutputFolderAndPrefix::ASCIIString,maxit = 10)

file = matopen(string(filenamePrefix,"_PARAM.mat"));
n_cells = read(file,"MinvN");
OmegaDomain = read(file,"MinvOmega");
Minv = getRegularMesh(OmegaDomain,n_cells);
HO = read(file,"HO");

boundsLow = read(file,"boundsLow");
boundsHigh = read(file,"boundsHigh");
mref =  read(file,"mref");
close(file);

resultsFilename = "";
if resultsOutputFolderAndPrefix!=""
	resultsFilename = string(resultsOutputFolderAndPrefix,tuple((Minv.n+1)...),".dat");
end
###########################################################

### Read receivers and sources files
RCVfile = string(filenamePrefix,"_rcvMap.dat");
SRCfile = string(filenamePrefix,"_srcMap.dat");

srcNodeMap = readSrcRcvLocationFile(SRCfile,Minv);
rcvNodeMap = readSrcRcvLocationFile(RCVfile,Minv);

Q = generateSrcRcvProjOperators(Minv.n+1,srcNodeMap);
Q = Q.*1/(norm(Minv.h)^2);
P = generateSrcRcvProjOperators(Minv.n+1,rcvNodeMap);

println("Travel time tomography: ",size(Q,2)," sources.");
#############################################################################################


println("Reading data:");

(DobsEik,WdEik) =  readDataFileToDataMat(string(filenamePrefix,"_travelTime.dat"),srcNodeMap,rcvNodeMap);




N = prod(Minv.n+1);

Iact = speye(Float16,N);
Iact = convert(SparseMatrixCSC{Float16,Int32},Iact);
mback   = zeros(Float64,N);


## Setting the sea constant:
mask = zeros(N);
sea = abs(m[:] .- maximum(m)) .< 1e-2;
mask[sea] = 1;
# # setup active cells
mback = vec(m[:].*mask);
Iact = Iact[:,mask .== 0.0];
boundsLow = Iact'*boundsLow;
boundsHigh = Iact'*boundsHigh;
mref = Iact'*mref[:];


########################################################################################################
##### Set up remote workers ############################################################################
########################################################################################################

EikMPIWorkers = nworkers(); # this just set the maximal MPI workers. To activate parallelism, run addprocs()

(pFor,contDiv,SourcesSubInd) = getEikonalInvParam(Minv,Q,P,HO,EikMPIWorkers);


misfun = SSDFun

jInvVersion = 2

if jInvVersion==1

	DobsRF = Array(RemoteRef{Channel{Any}},length(pFor))
	WdRF   = Array(RemoteRef{Channel{Any}},length(pFor))
	for i = contDiv[1]:contDiv[2]-1
		I_i = SourcesSubInd[i]; # subset of sources for ith worker.
		DobsRF[i] = remotecall(pFor[i].where, identity, DobsEik[:,I_i]);
		wait(DobsRF[i]);
		WdRF[i] = remotecall(pFor[i].where, identity, WdEik[:,I_i]);
		wait(WdRF[i]);
	end
	DobsEik = [];
	WdEik = [];

	Mesh2Mesh = Array(RemoteRef{Channel{Any}},length(pFor))	
	for i=1:length(Mesh2Mesh)
		k = pFor[i].where
		Mesh2Mesh[i] = remotecall(k,identity,1.0)
		wait(Mesh2Mesh[i]);
	end
	gloc = prepareGlobalToLocal(Mesh2Mesh,Iact,mback);
else
	pForMaster = Array(EikonalInvParam,length(pFor));
	pMisRFs    = Array(RemoteRef{Channel{Any}},length(pFor));
	for i=1:length(pFor)
		worker = pFor[i].where;
		pForMaster[i] = fetch(pFor[i]);
		I_i = SourcesSubInd[i]; # subset of sources for ith worker.
		pMisRFs[i] = remotecall(worker,getMisfitParam,pForMaster[i],WdEik[:,I_i],DobsEik[:,I_i],misfun,fMod,prepareGlobalToLocal(1.0,Iact,mback,"")); 
	end
end
########################################################################################################
##### Set up Inversion #################################################################################
########################################################################################################




maxStep=0.2*maximum(boundsHigh);

a = minimum(boundsLow)*0.8;
b = maximum(boundsHigh)*1.2;
modfun(x) = getBoundModel(x,a,b);
mref = getBoundModelInv(mref,a,b);
boundsHigh = boundsHigh*10000000.0;
boundsLow = -boundsLow*100000000.0

# function modfun(x)
	# return x, eye(length(x));
# end


cgit = 10; 
alpha = 1e+0;
pcgTol = 1e-1;

HesPrec=getSSORCGRegularizationPreconditioner(1.0,1e-5,1000)




################################################# GIT VERSION OF JINV #################################################


if jInvVersion==1
	regparams = [1.0,1.0,1.0,1e-2];
	regfun = wdiffusionRegNodal;
	
	pInv = getInverseParam(gloc,Minv,Iact,modfun,
                         regfun,alpha,mref[:],regparams,
                         misfun,DobsRF,WdRF,[],
                         boundsLow,boundsHigh,
                         maxStep=maxStep,pcgMaxIter=cgit,pcgTol=pcgTol,
						 minUpdate=1e-3, maxIter = maxit,HesPrec=HesPrec);

	function dump(mc,Dc,iter,pInv,PF)
		if resultsFilename!=""
			fullMc = reshape(pInv.Iact*pInv.modelfun(mc)[1] + mback,tuple((pInv.MInv.n+1)...));
			Temp = splitext(resultsFilename);
			Temp = string(Temp[1],"_GN",iter,Temp[2]);
			writedlm(Temp,convert(Array{Float16},fullMc));
			if plotting
				close(888);
				figure(888);
				plotModel(fullMc,true,false,[],0,[a/0.8,b/1.2],splitdir(Temp)[2]);
			end
		end
	end						 
						 
	tic()
	mc,Dc,flag = projGNCG(copy(mref[:]),pInv,pFor,indCredit = [],dumpResults = dump);
	toc()

	Dpred = Array(Array{Float64,2},length(pFor))
	for k = 1:length(pFor)
		Dpred[k] = fetch(Dc[k]);
	end
	Dpred = arrangeRemoteCallDataIntoLocalData(Dpred);

	if resultsFilename!=""
		Temp = splitext(resultsFilename);
		writedlm(string(Temp[1],"_predictedData",Temp[2]),Dpred);
		writedlm(string(Temp[1],"_recoveredModel",Temp[2]),reshape(pInv.Iact*pInv.modelfun(mc)[1] + mback,tuple((pInv.MInv.n+1)...)));
	end
else  ################################################ LARS VERSION OF JINV ##################################################
	
	regparams = [1.0,1.0,1.0,1e-2];
	regfun(m, mref, M) = wdiffusionRegNodal(m, mref, M, Iact=Iact, C = regparams);
	
	pInv = getInverseParam(Minv,modfun,regfun,alpha,mref[:],boundsLow,boundsHigh,
                         maxStep=maxStep,pcgMaxIter=cgit,pcgTol=pcgTol,
						 minUpdate=1e-3, maxIter = maxit,HesPrec=HesPrec);
	function dump(mc,Dc,iter,pInv,pMis)
		if resultsFilename!=""
			fullMc = reshape(Iact*modfun(mc)[1] + mback,tuple((pInv.MInv.n+1)...));
			Temp = splitext(resultsFilename);
			Temp = string(Temp[1],"_GN",iter,Temp[2]);
			writedlm(Temp,convert(Array{Float16},fullMc));
			if plotting
				close(888);
				figure(888);
				plotModel(fullMc,true,false,[],0,[a/0.8,b/1.2],splitdir(Temp)[2]);
			end
		end
	end						 
						 
	tic()
	mc,Dc,flag = projGNCG(copy(mref[:]),pInv,pMisRFs,indCredit = [],dumpResults = dump);
	toc()

	Dpred = Array(Array{Float64,2},length(pMisRFs))
	for k = 1:length(pMisRFs)
		Dpred[k] = fetch(Dc[k]);
	end
	Dpred = arrangeRemoteCallDataIntoLocalData(Dpred);

	if resultsFilename!=""
		Temp = splitext(resultsFilename);
		writedlm(string(Temp[1],"_predictedData",Temp[2]),convert(Array{Float16},Dpred));
		writedlm(string(Temp[1],"_recoveredModel",Temp[2]),convert(Array{Float16},reshape(Iact*modfun(mc)[1] + mback,tuple((pInv.MInv.n+1)...))));
	end
end

########################################################################################################################


return mc,Dpred;
end