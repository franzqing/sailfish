#define BLOCK_SIZE ${block_size}
#define PERIODIC_X ${periodic_x}
#define PERIODIC_Y ${periodic_y}
#define DIST_SIZE ${dist_size}
#define GEO_FLUID ${geo_fluid}
#define GEO_WALL ${geo_wall}
#define GEO_WALL_E ${geo_wall_e}
#define GEO_WALL_W ${geo_wall_w}
#define GEO_WALL_S ${geo_wall_s}
#define GEO_WALL_N ${geo_wall_n}
#define GEO_BCV ${geo_bcv}
#define GEO_BCP ${geo_bcp}

#define DT 1.0f

${const_var} float tau = ${tau}f;		// relaxation time
${const_var} float visc = ${visc}f;		// viscosity
${const_var} float geo_params[${num_params+1}] = {
% for param in geo_params:
	${param}f,
% endfor
0};		// geometry parameters

typedef struct Dist {
	float fC, fE, fW, fS, fN, fSE, fSW, fNE, fNW;
} Dist;

// Distribution in momentum space.
typedef struct DistM {
	float rho, en, ens, mx, ex, my, ey, sd, sod;
} DistM;

<%include file="opencl_compat.mako"/>

//
// Copy the idx-th distribution from din into dout.
//
${device_func} inline void getDist(Dist *dout, ${global_ptr} float *din, int idx)
{
	dout->fC = din[idx];
	dout->fE = din[DIST_SIZE + idx];
	dout->fW = din[DIST_SIZE*2 + idx];
	dout->fS = din[DIST_SIZE*3 + idx];
	dout->fN = din[DIST_SIZE*4 + idx];
	dout->fSE = din[DIST_SIZE*5 + idx];
	dout->fSW = din[DIST_SIZE*6 + idx];
	dout->fNE = din[DIST_SIZE*7 + idx];
	dout->fNW = din[DIST_SIZE*8 + idx];
}

${device_func} inline bool isWallNode(int type) {
	return type >= GEO_WALL && type <= GEO_WALL_S;
}

//
// Get macroscopic density rho and velocity v given a distribution fi, and
// the node class node_type.
//
${device_func} inline void getMacro(Dist fi, int node_type, float *rho, float *vx, float *vy)
{
	// Wall nodes are special, as some distributions (those pointing out of
	// the simulation grid) are undefined.
	if (isWallNode(node_type)) {
		switch (node_type) {
		case GEO_WALL:
			*rho = fi.fC + fi.fE + fi.fW + fi.fS + fi.fN + fi.fNE + fi.fNW + fi.fSE + fi.fSW;
			break;

		case GEO_WALL_E:
			*rho = 2.0f * (fi.fNE + fi.fE + fi.fSE) + fi.fC + fi.fS + fi.fN;
			break;

		case GEO_WALL_W:
			*rho = 2.0f * (fi.fNW + fi.fSW + fi.fW) + fi.fC + fi.fS + fi.fN;
			break;

		case GEO_WALL_S:
			*rho = 2.0f * (fi.fSW + fi.fS + fi.fSE) + fi.fC + fi.fE + fi.fW;
			break;

		case GEO_WALL_N:
			*rho = 2.0f * (fi.fNW + fi.fN + fi.fNE) + fi.fC + fi.fE + fi.fW;
			break;
		}

		*vx = 0.0f;
		*vy = 0.0f;
		return;
	}

	*rho = fi.fC + fi.fE + fi.fW + fi.fS + fi.fN + fi.fNE + fi.fNW + fi.fSE + fi.fSW;
	if (node_type >= GEO_BCV) {
		// Velocity boundary condition.
		if (node_type < GEO_BCP) {
			int idx = (node_type - GEO_BCV) * 2;
			*vx = geo_params[idx];
			*vy = geo_params[idx+1];
			return;
		// Pressure boundary condition.
		} else {
			// c_s^2 = 1/3, P/c_s^2 = rho
			int idx = (GEO_BCP-GEO_BCV) * 2 + (node_type - GEO_BCP);
			*rho = geo_params[idx] * 3.0f;
		}
	}

	*vx = (fi.fE + fi.fSE + fi.fNE - fi.fW - fi.fSW - fi.fNW) / *rho + 0.5f * ${ext_accel_x};
	*vy = (fi.fN + fi.fNW + fi.fNE - fi.fS - fi.fSW - fi.fSE) / *rho + 0.5f * ${ext_accel_y};
}

//
// A kernel to update the position of tracer particles.
//
// Each thread updates the position of a single particle using Euler's algorithm.
//
${kernel} void LBMUpdateTracerParticles(${global_ptr} float *dist, ${global_ptr} int *map,
		${global_ptr} float *x, ${global_ptr} float *y)
{
	float rho, vx, vy;

	int gi = get_global_id(0);
	float cx = x[gi];
	float cy = y[gi];

	int ix = (int)(cx);
	int iy = (int)(cy);

	// Sanity checks.
	if (iy < 0)
		iy = 0;

	if (ix < 0)
		ix = 0;

	if (ix > ${lat_w-1})
		ix = ${lat_w-1};

	if (iy > ${lat_h-1})
		iy = ${lat_h-1};

	int idx = ix + ${lat_w}*iy;

	Dist fc;

## HACK: If a call to getDist() is made below, the overall performance of the simulation
## will be decreased by a factor of 2, regardless of whether this kernel is even executed.
## This might be caused by the NVIDIA OpenCL compiler not inlining the getDist function.
## To avoid the performance loss, we temporarily inline getDist manually.
	// getDist(&fc, dist, idx);
	fc.fC = dist[idx];
	fc.fE = dist[DIST_SIZE + idx];
	fc.fW = dist[DIST_SIZE*2 + idx];
	fc.fS = dist[DIST_SIZE*3 + idx];
	fc.fN = dist[DIST_SIZE*4 + idx];
	fc.fSE = dist[DIST_SIZE*5 + idx];
	fc.fSW = dist[DIST_SIZE*6 + idx];
	fc.fNE = dist[DIST_SIZE*7 + idx];
	fc.fNW = dist[DIST_SIZE*8 + idx];

	getMacro(fc, map[idx], &rho, &vx, &vy);

	cx = cx + vx * DT;
	cy = cy + vy * DT;

	// Periodic boundary conditions.
	if (cx > ${lat_w})
		cx = 0.0f;

	if (cy > ${lat_h})
		cy = 0.0f;

	if (cx < 0.0f)
		cx = (float)${lat_w};

	if (cy < 0.0f)
		cy = (float)${lat_h};

	x[gi] = cx;
	y[gi] = cy;
}

% if model == 'mrt':
//
// Relaxation in moment space.
//
${device_func} void MS_relaxate(Dist *fi, int node_type)
{
	DistM fm, feq;

	fm.rho = 1.0f*fi->fC + 1.0f*fi->fE + 1.0f*fi->fN + 1.0f*fi->fW + 1.0f*fi->fS + 1.0f*fi->fNE + 1.0f*fi->fNW + 1.0f*fi->fSW + 1.0f*fi->fSE;
	fm.en = -4.0f*fi->fC - 1.0f*fi->fE - 1.0f*fi->fN - 1.0f*fi->fW - 1.0f*fi->fS + 2.0f*fi->fNE + 2.0f*fi->fNW + 2.0f*fi->fSW + 2.0f*fi->fSE;
	fm.ens = 4.0f*fi->fC - 2.0f*fi->fE - 2.0f*fi->fN - 2.0f*fi->fW - 2.0f*fi->fS + 1.0f*fi->fNE + 1.0f*fi->fNW + 1.0f*fi->fSW + 1.0f*fi->fSE;
	fm.mx =  0.0f*fi->fC + 1.0f*fi->fE + 0.0f*fi->fN - 1.0f*fi->fW + 0.0f*fi->fS + 1.0f*fi->fNE - 1.0f*fi->fNW - 1.0f*fi->fSW + 1.0f*fi->fSE;
	fm.ex =  0.0f*fi->fC - 2.0f*fi->fE + 0.0f*fi->fN + 2.0f*fi->fW + 0.0f*fi->fS + 1.0f*fi->fNE - 1.0f*fi->fNW - 1.0f*fi->fSW + 1.0f*fi->fSE;
	fm.my =  0.0f*fi->fC + 0.0f*fi->fE + 1.0f*fi->fN + 0.0f*fi->fW - 1.0f*fi->fS + 1.0f*fi->fNE + 1.0f*fi->fNW - 1.0f*fi->fSW - 1.0f*fi->fSE;
	fm.ey =  0.0f*fi->fC + 0.0f*fi->fE - 2.0f*fi->fN + 0.0f*fi->fW + 2.0f*fi->fS + 1.0f*fi->fNE + 1.0f*fi->fNW - 1.0f*fi->fSW - 1.0f*fi->fSE;
	fm.sd =  0.0f*fi->fC + 1.0f*fi->fE - 1.0f*fi->fN + 1.0f*fi->fW - 1.0f*fi->fS + 0.0f*fi->fNE + 0.0f*fi->fNW + 0.0f*fi->fSW - 0.0f*fi->fSE;
	fm.sod = 0.0f*fi->fC + 0.0f*fi->fE + 0.0f*fi->fN + 0.0f*fi->fW + 0.0f*fi->fS + 1.0f*fi->fNE - 1.0f*fi->fNW + 1.0f*fi->fSW - 1.0f*fi->fSE;

	if (node_type >= GEO_BCV) {
		// Velocity boundary condition.
		if (node_type < GEO_BCP) {
			int idx = (node_type - GEO_BCV) * 2;
			fm.mx = geo_params[idx];
			fm.my = geo_params[idx+1];
		// Pressure boundary condition.
		} else {
			int idx = (GEO_BCP-GEO_BCV) * 2 + (node_type - GEO_BCP);
			fm.rho = geo_params[idx] * 3.0f;
		}
	}

	float h = fm.mx*fm.mx + fm.my*fm.my;
	feq.en  = -2.0f*fm.rho + 3.0f*h;
	feq.ens = fm.rho - 3.0f*h;
	feq.ex  = -fm.mx;
	feq.ey  = -fm.my;
	feq.sd  = (fm.mx*fm.mx - fm.my*fm.my);
	feq.sod = (fm.mx*fm.my);

	float tau7 = 4.0f / (12.0f*visc + 2.0f);
	float tau4 = 3.0f*(2.0f - tau7) / (3.0f - tau7);
	float tau8 = 1.0f/((2.0f/tau7 - 1.0f)*0.5f + 0.5f);

	if (node_type == GEO_FLUID || isWallNode(node_type)) {
		fm.en  -= 1.63f * (fm.en - feq.en);
		fm.ens -= 1.14f * (fm.ens - feq.ens);
		fm.ex  -= tau4 * (fm.ex - feq.ex);
		fm.ey  -= 1.92f * (fm.ey - feq.ey);
		fm.sd  -= tau7 * (fm.sd - feq.sd);
		fm.sod -= tau8 * (fm.sod - feq.sod);
	} else {
		fm.en  = feq.en;
		fm.ens = feq.ens;
		fm.ex  = feq.ex;
		fm.ey  = feq.ey;
		fm.sd  = feq.sd;
		fm.sod = feq.sod;
	}

	fi->fC  = (1.0f/9.0f)*fm.rho - (1.0f/9.0f)*fm.en + (1.0f/9.0f)*fm.ens;
	fi->fE  = (1.0f/9.0f)*fm.rho - (1.0f/36.0f)*fm.en - (1.0f/18.0f)*fm.ens + (1.0f/6.0f)*fm.mx - (1.0f/6.0f)*fm.ex + 0.25f*fm.sd;
	fi->fN  = (1.0f/9.0f)*fm.rho - (1.0f/36.0f)*fm.en - (1.0f/18.0f)*fm.ens + (1.0f/6.0f)*fm.my - (1.0f/6.0f)*fm.ey - 0.25f*fm.sd;
	fi->fW  = (1.0f/9.0f)*fm.rho - (1.0f/36.0f)*fm.en - (1.0f/18.0f)*fm.ens - (1.0f/6.0f)*fm.mx + (1.0f/6.0f)*fm.ex + 0.25f*fm.sd;
	fi->fS  = (1.0f/9.0f)*fm.rho - (1.0f/36.0f)*fm.en - (1.0f/18.0f)*fm.ens - (1.0f/6.0f)*fm.my + (1.0f/6.0f)*fm.ey - 0.25f*fm.sd;
	fi->fNE = (1.0f/9.0f)*fm.rho + (1.0f/18.0f)*fm.en + (1.0f/36.0f)*fm.ens +
			 +(1.0f/6.0f)*fm.mx + (1.0f/12.0f)*fm.ex + (1.0f/6.0f)*fm.my + (1.0f/12.0f)*fm.ey + 0.25f*fm.sod;
	fi->fNW = (1.0f/9.0f)*fm.rho + (1.0f/18.0f)*fm.en + (1.0f/36.0f)*fm.ens +
			 -(1.0f/6.0f)*fm.mx - (1.0f/12.0f)*fm.ex + (1.0f/6.0f)*fm.my + (1.0f/12.0f)*fm.ey - 0.25f*fm.sod;
	fi->fSW = (1.0f/9.0f)*fm.rho + (1.0f/18.0f)*fm.en + (1.0f/36.0f)*fm.ens +
			 -(1.0f/6.0f)*fm.mx - (1.0f/12.0f)*fm.ex - (1.0f/6.0f)*fm.my - (1.0f/12.0f)*fm.ey + 0.25f*fm.sod;
	fi->fSE = (1.0f/9.0f)*fm.rho + (1.0f/18.0f)*fm.en + (1.0f/36.0f)*fm.ens +
			 +(1.0f/6.0f)*fm.mx + (1.0f/12.0f)*fm.ex - (1.0f/6.0f)*fm.my - (1.0f/12.0f)*fm.ey - 0.25f*fm.sod;
}
% endif

% if model == 'bgk':
//
// Performs the relaxation step in the BGK model given the density rho,
// the velocity v and the distribution fi.
//
${device_func} void BGK_relaxate(float rho, float vx, float vy, Dist *fi, int node_type)
{
	// relaxation
	float Cusq = -1.5f * (vx*vx + vy*vy);
	Dist feq;

	feq.fC = rho * (1.0f + Cusq) * 4.0f/9.0f;
	feq.fN = rho * (1.0f + Cusq + 3.0f*vy + 4.5f*vy*vy) / 9.0f;
	feq.fE = rho * (1.0f + Cusq + 3.0f*vx + 4.5f*vx*vx) / 9.0f;
	feq.fS = rho * (1.0f + Cusq - 3.0f*vy + 4.5f*vy*vy) / 9.0f;
	feq.fW = rho * (1.0f + Cusq - 3.0f*vx + 4.5f*vx*vx) / 9.0f;
	feq.fNE = rho * (1.0f + Cusq + 3.0f*(vx+vy) + 4.5f*(vx+vy)*(vx+vy)) / 36.0f;
	feq.fSE = rho * (1.0f + Cusq + 3.0f*(vx-vy) + 4.5f*(vx-vy)*(vx-vy)) / 36.0f;
	feq.fSW = rho * (1.0f + Cusq + 3.0f*(-vx-vy) + 4.5f*(vx+vy)*(vx+vy)) / 36.0f;
	feq.fNW = rho * (1.0f + Cusq + 3.0f*(-vx+vy) + 4.5f*(-vx+vy)*(-vx+vy)) / 36.0f;

	if (node_type == GEO_FLUID || isWallNode(node_type)) {
		fi->fC += (feq.fC - fi->fC) / tau;
		fi->fE += (feq.fE - fi->fE) / tau;
		fi->fW += (feq.fW - fi->fW) / tau;
		fi->fS += (feq.fS - fi->fS) / tau;
		fi->fN += (feq.fN - fi->fN) / tau;
		fi->fSE += (feq.fSE - fi->fSE) / tau;
		fi->fNE += (feq.fNE - fi->fNE) / tau;
		fi->fSW += (feq.fSW - fi->fSW) / tau;
		fi->fNW += (feq.fNW - fi->fNW) / tau;
	} else {
		fi->fC  = feq.fC;
		fi->fE  = feq.fE;
		fi->fW  = feq.fW;
		fi->fS  = feq.fS;
		fi->fN  = feq.fN;
		fi->fSE = feq.fSE;
		fi->fNE = feq.fNE;
		fi->fSW = feq.fSW;
		fi->fNW = feq.fNW;
	}

	// External acceleration.
	float pref = rho * (3.0f - 3.0f/(2.0f * tau));
	#define eax ${ext_accel_x}
	#define eay ${ext_accel_y}
	float ue = eax*vx + eay*vy;

	fi->fC += pref*(-ue) * 4.0f/9.0f;
	fi->fN += pref*(eay - ue + 3.0f*(eay*vy)) / 9.0f;
	fi->fE += pref*(eax - ue + 3.0f*(eax*vx)) / 9.0f;
	fi->fS += pref*(-eay - ue + 3.0f*(eay*vy)) / 9.0f;
	fi->fW += pref*(-eax - ue + 3.0f*(eax*vx)) / 9.0f;
	fi->fNE += pref*(eax + eay - ue + 3.0f*((vx+vy)*(eax+eay))) / 36.0f;
	fi->fSE += pref*(eax - eay - ue + 3.0f*((vx-vy)*(eax-eay))) / 36.0f;
	fi->fSW += pref*(-eax - eay - ue + 3.0f*((vx+vy)*(eax+eay))) / 36.0f;
	fi->fNW += pref*(-eax + eay - ue + 3.0f*((-vx+vy)*(-eax+eay))) / 36.0f;
}
% endif

// TODO:
// - try having dummy nodes as the edges of the lattice to avoid divergent threads

${kernel} void LBMCollideAndPropagate(${global_ptr} int *map, ${global_ptr} float *dist_in,
		${global_ptr} float *dist_out, ${global_ptr} float *orho, ${global_ptr} float *ovx,
		${global_ptr} float *ovy, int save_macro)
{
	int tix = get_local_id(0);
	int ti = get_global_id(0);
	int gi = ti + ${lat_w}*get_group_id(1);

	// shared variables for in-block propagation
	${shared_var} float fo_E[BLOCK_SIZE];
	${shared_var} float fo_W[BLOCK_SIZE];
	${shared_var} float fo_SE[BLOCK_SIZE];
	${shared_var} float fo_SW[BLOCK_SIZE];
	${shared_var} float fo_NE[BLOCK_SIZE];
	${shared_var} float fo_NW[BLOCK_SIZE];

	// cache the distribution in local variables
	Dist fi;
	getDist(&fi, dist_in, gi);

	int type = map[gi];

	if (isWallNode(type)) {
		float t;
		t = fi.fE;
		fi.fE = fi.fW;
		fi.fW = t;

		t = fi.fNW;
		fi.fNW = fi.fSE;
		fi.fSE = t;

		t = fi.fNE;
		fi.fNE = fi.fSW;
		fi.fSW = t;

		t = fi.fN;
		fi.fN = fi.fS;
		fi.fS = t;
	}

	// macroscopic quantities for the current cell
	float rho, vx, vy;
	getMacro(fi, type, &rho, &vx, &vy);

	// only save the macroscopic quantities if requested to do so
	if (save_macro == 1) {
		orho[gi] = rho;
		ovx[gi] = vx;
		ovy[gi] = vy;
	}


	% if model == 'bgk':
		BGK_relaxate(rho, vx, vy, &fi, map[gi]);
	% else:
		MS_relaxate(&fi, map[gi]);
	% endif

	#define dir_fC 0
	#define dir_fE 1
	#define dir_fW 2
	#define dir_fS 3
	#define dir_fN 4
	#define dir_fSE 5
	#define dir_fSW 6
	#define dir_fNE 7
	#define dir_fNW 8

	#define dir_idx(idx) dir_##idx
	#define set_odist(idx, dir, val) dist_out[DIST_SIZE*dir_idx(dir) + idx] = val
	#define rel(x,y) ((x) + ${lat_w}*(y))

	// update the 0-th direction distribution
	set_odist(gi, fC, fi.fC);

	// E propagation in shared memory
	if (tix < get_local_size(0)-1) {
		fo_E[tix+1] = fi.fE;
		fo_NE[tix+1] = fi.fNE;
		fo_SE[tix+1] = fi.fSE;
	// E propagation in global memory (at right block boundary)
	} else if (ti < ${lat_w-1}) {
		set_odist(gi+rel(1,0), fE, fi.fE);
		if (get_group_id(1) > 0)			set_odist(gi+rel(1,-1), fSE, fi.fSE);
		else if (PERIODIC_Y)		set_odist(ti+${lat_w*(lat_h-1)+1}, fSE, fi.fSE);
		if (get_group_id(1) < ${lat_h-1})	set_odist(gi+rel(1,1), fNE, fi.fNE);
		else if (PERIODIC_Y)		set_odist(ti+1, fNE, fi.fNE);
	} else if (PERIODIC_X) {
		set_odist(gi+rel(${-lat_w+1}, 0), fE, fi.fE);
		if (get_group_id(1) > 0)			set_odist(gi+rel(${-lat_w+1},-1), fSE, fi.fSE);
		else if (PERIODIC_Y)		set_odist(rel(0, ${lat_h-1}), fSE, fi.fSE);
		if (get_group_id(1) < ${lat_h-1})	set_odist(gi+rel(${-lat_w+1},1), fNE, fi.fNE);
		else if (PERIODIC_Y)		set_odist(rel(0, 0), fNE, fi.fNE);
	}

	// W propagation in shared memory
	if (tix > 0) {
		fo_W[tix-1] = fi.fW;
		fo_NW[tix-1] = fi.fNW;
		fo_SW[tix-1] = fi.fSW;
	// W propagation in global memory (at left block boundary)
	} else if (ti > 0) {
		set_odist(gi+rel(-1,0), fW, fi.fW);
		if (get_group_id(1) > 0)			set_odist(gi+rel(-1,-1), fSW, fi.fSW);
		else if (PERIODIC_Y)		set_odist(ti+${lat_w*(lat_h-1)-1}, fSW, fi.fSW);
		if (get_group_id(1) < ${lat_h-1})	set_odist(gi+rel(-1,1), fNW, fi.fNW);
		else if (PERIODIC_Y)		set_odist(ti-1, fNW, fi.fNW);
	} else if (PERIODIC_X) {
		set_odist(gi+rel(${lat_w-1},0), fW, fi.fW);
		if (get_group_id(1) > 0)			set_odist(gi+rel(${lat_w-1},-1), fSW, fi.fSW);
		else if (PERIODIC_Y)		set_odist(${lat_h*lat_w-1}, fSW, fi.fSW);
		if (get_group_id(1) < ${lat_h-1})	set_odist(gi+rel(${lat_w-1},1), fNW, fi.fNW);
		else if (PERIODIC_Y)		set_odist(${lat_w-1}, fNW, fi.fNW);
	}

% if backend == 'cuda':
	__syncthreads();
% else:
	barrier(CLK_LOCAL_MEM_FENCE);
% endif

	// the leftmost thread is not updated in this block
	if (tix > 0) {
		set_odist(gi, fE, fo_E[tix]);
		if (get_group_id(1) > 0)			set_odist(gi-${lat_w}, fSE, fo_SE[tix]);
		else if (PERIODIC_Y)		set_odist(gi+${lat_w*(lat_h-1)}, fSE, fo_SE[tix]);
		if (get_group_id(1) < ${lat_h-1})	set_odist(gi+${lat_w}, fNE, fo_NE[tix]);
		else if (PERIODIC_Y)		set_odist(ti, fNE, fo_NE[tix]);
	}

	// N + S propagation (global memory)
	if (get_group_id(1) > 0)			set_odist(gi-${lat_w}, fS, fi.fS);
	else if (PERIODIC_Y)		set_odist(ti+${lat_w*(lat_h-1)}, fS, fi.fS);
	if (get_group_id(1) < ${lat_h-1})	set_odist(gi+${lat_w}, fN, fi.fN);
	else if (PERIODIC_Y)		set_odist(ti, fN, fi.fN);

	// the rightmost thread is not updated in this block
	if (tix < get_local_size(0)-1) {
		set_odist(gi, fW, fo_W[tix]);
		if (get_group_id(1) > 0)			set_odist(gi-${lat_w}, fSW, fo_SW[tix]);
		else if (PERIODIC_Y)		set_odist(gi+${lat_w*(lat_h-1)}, fSW, fo_SW[tix]);
		if (get_group_id(1) < ${lat_h-1})	set_odist(gi+${lat_w}, fNW, fo_NW[tix]);
		else if (PERIODIC_Y)		set_odist(ti, fNW, fo_NW[tix]);
	}
}

