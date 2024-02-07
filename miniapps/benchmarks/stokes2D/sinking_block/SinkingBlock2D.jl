using JustRelax
using ParallelStencil
@init_parallel_stencil(Threads, Float64, 2)

using JustPIC
using JustPIC._2D
# Threads is the default backend,
# to run on a CUDA GPU load CUDA.jl (i.e. "using CUDA") at the beginning of the script,
# and to run on an AMD GPU load AMDGPU.jl (i.e. "using AMDGPU") at the beginning of the script.
const backend = CPUBackend # Options: CPUBackend, CUDABackend, AMDGPUBackend

# setup ParallelStencil.jl environment
model = PS_Setup(:Threads, Float64, 2)
environment!(model)

using Printf, LinearAlgebra, GeoParams, GLMakie, CellArrays

## SET OF HELPER FUNCTIONS PARTICULAR FOR THIS SCRIPT --------------------------------

# Thermal rectangular perturbation
function rectangular_perturbation!(T, xc, yc, r, xvi)

    @parallel_indices (i, j) function _rectangular_perturbation!(T, xc, yc, r, x, y)
        @inbounds if ((x[i]-xc)^2 ≤ r^2) && ((y[j] - yc)^2 ≤ r^2)
            depth       = abs(y[j])
            dTdZ        = (2047 - 2017) / 50e3
            offset      = 2017
            T[i + 1, j] = (depth - 585e3) * dTdZ + offset
        end
        return nothing
    end
    ni = length.(xvi)
    @parallel (@idx ni) _rectangular_perturbation!(T, xc, yc, r, xvi...)

    return nothing
end

function init_phases!(phases, particles, xc, yc, r)
    ni = size(phases)

    @parallel_indices (i, j) function init_phases!(phases, px, py, index, xc, yc, r)
        @inbounds for ip in JustRelax.cellaxes(phases)
            # quick escape
            JustRelax.@cell(index[ip, i, j]) == 0 && continue

            x = JustRelax.@cell px[ip, i, j]
            depth = -(JustRelax.@cell py[ip, i, j])
            # plume - rectangular
            JustRelax.@cell phases[ip, i, j] = if ((x -xc)^2 ≤ r^2) && ((depth - yc)^2 ≤ r^2)
                2.0
            else
                1.0
            end
        end
        return nothing
    end

    @parallel (JustRelax.@idx ni) init_phases!(phases, particles.coords..., particles.index, xc, yc, r)
end

import ParallelStencil.INDICES
const idx_j = INDICES[2]
macro all_j(A)
    esc(:($A[$idx_j]))
end

@parallel function init_P!(P, ρg, z)
    @all(P) = @all(ρg)*abs(@all_j(z))
    return nothing
end

# --------------------------------------------------------------------------------
# BEGIN MAIN SCRIPT
# --------------------------------------------------------------------------------
function sinking_block2D(igg; ar=8, ny=16, nx=ny*8, figdir="figs2D", thermal_perturbation = :circular)

    # Physical domain ------------------------------------
    ly           = 500e3
    lx           = ly * ar
    origin       = 0.0, -ly                         # origin coordinates
    ni           = nx, ny                           # number of cells
    li           = lx, ly                           # domain length in x- and y-
    di           = @. li / (nx_g(), ny_g()) # grid step in x- and -y
    grid         = Geometry(ni, li; origin = origin)
    (; xci, xvi) = grid # nodes at the center and vertices of the cells
    # ----------------------------------------------------

    # Physical properties using GeoParams ----------------
    δρ = 100
    rheology = (
        SetMaterialParams(;
            Name              = "Mantle",
            Phase             = 1,
            Density           = ConstantDensity(; ρ=3.2e3),
            CompositeRheology = CompositeRheology((LinearViscous(; η = 1e21), )),
            Gravity           = ConstantGravity(; g=9.81),
        ),
        SetMaterialParams(;
            Name              = "Block",
            Phase             = 2,
            Density           = ConstantDensity(; ρ=3.2e3 + δρ),
            CompositeRheology = CompositeRheology((LinearViscous(; η = 1e23), )),
            Gravity           = ConstantGravity(; g=9.81),
        )
    )
    # heat diffusivity
    dt = 1
    # ----------------------------------------------------

    # Initialize particles -------------------------------
    nxcell, max_xcell, min_xcell = 20, 20, 1
    particles = init_particles(
        backend, nxcell, max_xcell, min_xcell, xvi..., di..., ni...
    )
    # temperature
    pPhases,      = init_cell_arrays(particles, Val(1))
    particle_args = (pPhases, )
    # Rectangular density anomaly
    xc_anomaly   =  250e3   # origin of thermal anomaly
    yc_anomaly   = -(ly-400e3) # origin of thermal anomaly
    r_anomaly    =  50e3   # radius of perturbation
    init_phases!(pPhases, particles, xc_anomaly, abs(yc_anomaly), r_anomaly)
    phase_ratios = PhaseRatio(ni, length(rheology))
    @parallel (@idx ni) phase_ratios_center(phase_ratios.center, pPhases)

    # STOKES ---------------------------------------------
    # Allocate arrays needed for every Stokes problem
    stokes    = StokesArrays(ni, ViscoElastic)
    pt_stokes = PTStokesCoeffs(li, di; ϵ=1e-5,  CFL = 0.95 / √2.1)
    # Buoyancy forces
    ρg        = @zeros(ni...), @zeros(ni...)
    @parallel (JustRelax.@idx ni) compute_ρg!(ρg[2], phase_ratios.center, rheology, (T=@ones(ni...), P=stokes.P))
    @parallel init_P!(stokes.P, ρg[2], xci[2])
    # ----------------------------------------------------

    # Viscosity
    η        = @ones(ni...)
    args     = (; dt = Inf)
    η_cutoff = -Inf, Inf
    @parallel (@idx ni) compute_viscosity!(
        η, 1.0, phase_ratios.center, @strain(stokes)..., args, rheology, η_cutoff
    )
    η_vep   = deepcopy(η)
    # ----------------------------------------------------

    # Boundary conditions
    flow_bcs = FlowBoundaryConditions(;
        free_slip    = (left =  true, right =  true, top =  true, bot =  true),
        periodicity  = (left = false, right = false, top = false, bot = false),
    )
    flow_bcs!(stokes, flow_bcs) # apply boundary conditions
    update_halo!(stokes.V.Vx, stokes.V.Vy)

    # Stokes solver ----------------
    args = (; T = @ones(ni...), P = stokes.P, dt=Inf)
    solve!(
        stokes,
        pt_stokes,
        di,
        flow_bcs,
        ρg,
        η,
        η_vep,
        phase_ratios,
        rheology,
        args,
        Inf,
        igg;
        iterMax=150e3,
        nout=1e3,
        viscosity_cutoff = η_cutoff
    );
    dt = compute_dt(stokes, di, igg)
    # ------------------------------

    Vx_v    = @zeros(ni.+1...)
    Vy_v    = @zeros(ni.+1...)
    JustRelax.velocity2vertex!(Vx_v, Vy_v, @velocity(stokes)...)
    velocity = @. √(Vx_v^2 + Vy_v^2 )

    # Plotting ---------------------
    f, _, h = heatmap(velocity, colormap=:vikO)
    Colorbar(f[1,2], h)
    f
    # ------------------------------

    return nothing
end

ar     = 1 # aspect ratio
n      = 128
nx     = n*ar - 2
ny     = n - 2
igg    = if !(JustRelax.MPI.Initialized()) # initialize (or not) MPI grid
    IGG(init_global_grid(nx, ny, 1; init_MPI= true)...)
else
    igg
end

sinking_block2D(igg; ar=ar, nx=nx, ny=ny);
