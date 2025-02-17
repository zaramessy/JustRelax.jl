module JustRelax2D

using JustRelax: JustRelax
using AMDGPU
using StaticArrays
using CellArrays
using ParallelStencil, ParallelStencil.FiniteDifferences2D
using ImplicitGlobalGrid
using GeoParams, LinearAlgebra, Printf
using MPI

import JustRelax.JustRelax2D as JR2D

import JustRelax:
    IGG,
    BackendTrait,
    CPUBackendTrait,
    AMDGPUBackendTrait,
    backend,
    CPUBackend,
    AMDGPUBackend,
    Geometry,
    @cell
import JustRelax:
    AbstractBoundaryConditions,
    TemperatureBoundaryConditions,
    AbstractFlowBoundaryConditions,
    DisplacementBoundaryConditions,
    VelocityBoundaryConditions

@init_parallel_stencil(AMDGPU, Float64, 2)

include("../../common.jl")
include("../../stokes/Stokes2D.jl")

# Types
function JR2D.StokesArrays(::Type{AMDGPUBackend}, ni::NTuple{N,Integer}) where {N}
    return StokesArrays(ni)
end

function JR2D.ThermalArrays(::Type{AMDGPUBackend}, ni::NTuple{N,Number}) where {N}
    return ThermalArrays(ni...)
end

function JR2D.ThermalArrays(::Type{AMDGPUBackend}, ni::Vararg{Number,N}) where {N}
    return ThermalArrays(ni...)
end

function JR2D.PhaseRatio(::Type{AMDGPUBackend}, ni, num_phases)
    return PhaseRatio(ni, num_phases)
end

function JR2D.PTThermalCoeffs(
    ::Type{AMDGPUBackend}, K, ρCp, dt, di::NTuple, li::NTuple; ϵ=1e-8, CFL=0.9 / √3
)
    return PTThermalCoeffs(K, ρCp, dt, di, li; ϵ=ϵ, CFL=CFL)
end

function JR2D.PTThermalCoeffs(
    ::Type{AMDGPUBackend},
    rheology,
    phase_ratios,
    args,
    dt,
    ni,
    di::NTuple{nDim,T},
    li::NTuple{nDim,Any};
    ϵ=1e-8,
    CFL=0.9 / √3,
) where {nDim,T}
    return PTThermalCoeffs(rheology, phase_ratios, args, dt, ni, di, li; ϵ=ϵ, CFL=CFL)
end

function JR2D.PTThermalCoeffs(
    ::Type{AMDGPUBackend},
    rheology::MaterialParams,
    args,
    dt,
    ni,
    di::NTuple,
    li::NTuple;
    ϵ=1e-8,
    CFL=0.9 / √3,
)
    return PTThermalCoeffs(rheology, args, dt, ni, di, li; ϵ=ϵ, CFL=CFL)
end

function JR2D.update_thermal_coeffs!(
    pt_thermal::JustRelax.PTThermalCoeffs{T,<:ROCArray}, rheology, phase_ratios, args, dt
) where {T}
    ni = size(pt_thermal.dτ_ρ)
    @parallel (@idx ni) compute_pt_thermal_arrays!(
        pt_thermal.θr_dτ,
        pt_thermal.dτ_ρ,
        rheology,
        phase_ratios.center,
        args,
        pt_thermal.max_lxyz,
        pt_thermal.Vpdτ,
        inv(dt),
    )
    return nothing
end

function JR2D.update_thermal_coeffs!(
    pt_thermal::JustRelax.PTThermalCoeffs{T,<:ROCArray}, rheology, args, dt
) where {T}
    ni = size(pt_thermal.dτ_ρ)
    @parallel (@idx ni) compute_pt_thermal_arrays!(
        pt_thermal.θr_dτ,
        pt_thermal.dτ_ρ,
        rheology,
        args,
        pt_thermal.max_lxyz,
        pt_thermal.Vpdτ,
        inv(dt),
    )
    return nothing
end

function JR2D.update_thermal_coeffs!(
    pt_thermal::JustRelax.PTThermalCoeffs{T,<:ROCArray}, rheology, ::Nothing, args, dt
) where {T}
    ni = size(pt_thermal.dτ_ρ)
    @parallel (@idx ni) compute_pt_thermal_arrays!(
        pt_thermal.θr_dτ,
        pt_thermal.dτ_ρ,
        rheology,
        args,
        pt_thermal.max_lxyz,
        pt_thermal.Vpdτ,
        inv(dt),
    )
    return nothing
end

# Boundary conditions
function JR2D.flow_bcs!(
    ::AMDGPUBackendTrait, stokes::JustRelax.StokesArrays, bcs::VelocityBoundaryConditions
)
    return _flow_bcs!(bcs, @velocity(stokes))
end

function flow_bcs!(
    ::AMDGPUBackendTrait, stokes::JustRelax.StokesArrays, bcs::VelocityBoundaryConditions
)
    return _flow_bcs!(bcs, @velocity(stokes))
end

function JR2D.flow_bcs!(
    ::AMDGPUBackendTrait,
    stokes::JustRelax.StokesArrays,
    bcs::DisplacementBoundaryConditions,
)
    return _flow_bcs!(bcs, @displacement(stokes))
end

function flow_bcs!(
    ::AMDGPUBackendTrait,
    stokes::JustRelax.StokesArrays,
    bcs::DisplacementBoundaryConditions,
)
    return _flow_bcs!(bcs, @displacement(stokes))
end

function JR2D.thermal_bcs!(::AMDGPUBackendTrait, thermal::JustRelax.ThermalArrays, bcs)
    return thermal_bcs!(thermal.T, bcs)
end

function thermal_bcs!(::AMDGPUBackendTrait, thermal::JustRelax.ThermalArrays, bcs)
    return thermal_bcs!(thermal.T, bcs)
end

# Phases
function JR2D.phase_ratios_center!(
    ::AMDGPUBackendTrait,
    phase_ratios::JustRelax.PhaseRatio,
    particles,
    grid::Geometry,
    phases,
)
    return _phase_ratios_center!(phase_ratios, particles, grid, phases)
end

# Rheology

## viscosity
function JR2D.compute_viscosity!(::AMDGPUBackendTrait, stokes, ν, args, rheology, cutoff)
    return _compute_viscosity!(stokes, ν, args, rheology, cutoff)
end

function JR2D.compute_viscosity!(
    ::AMDGPUBackendTrait, stokes, ν, phase_ratios, args, rheology, cutoff
)
    return _compute_viscosity!(stokes, ν, phase_ratios, args, rheology, cutoff)
end

function JR2D.compute_viscosity!(η, ν, εII::ROCArray, args, rheology, cutoff)
    return compute_viscosity!(η, ν, εII, args, rheology, cutoff)
end

function compute_viscosity!(::AMDGPUBackendTrait, stokes, ν, args, rheology, cutoff)
    return _compute_viscosity!(stokes, ν, args, rheology, cutoff)
end

function compute_viscosity!(
    ::AMDGPUBackendTrait, stokes, ν, phase_ratios, args, rheology, cutoff
)
    return _compute_viscosity!(stokes, ν, phase_ratios, args, rheology, cutoff)
end

function compute_viscosity!(η, ν, εII::ROCArray, args, rheology, cutoff)
    return compute_viscosity!(η, ν, εII, args, rheology, cutoff)
end

## Stress
function JR2D.tensor_invariant!(::AMDGPUBackendTrait, A::JustRelax.SymmetricTensor)
    return _tensor_invariant!(A)
end

## Buoyancy forces
function JR2D.compute_ρg!(ρg::ROCArray, rheology, args)
    return compute_ρg!(ρg, rheology, args)
end
function JR2D.compute_ρg!(ρg::ROCArray, phase_ratios::JustRelax.PhaseRatio, rheology, args)
    return compute_ρg!(ρg, phase_ratios, rheology, args)
end

## Melt fraction
function JR2D.compute_melt_fraction!(ϕ::ROCArray, rheology, args)
    return compute_melt_fraction!(ϕ, rheology, args)
end

function JR2D.compute_melt_fraction!(
    ϕ::ROCArray, phase_ratios::JustRelax.PhaseRatio, rheology, args
)
    return compute_melt_fraction!(ϕ, phase_ratios, rheology, args)
end

# Interpolations
function JR2D.temperature2center!(::AMDGPUBackendTrait, thermal::JustRelax.ThermalArrays)
    return _temperature2center!(thermal)
end

function temperature2center!(::AMDGPUBackendTrait, thermal::JustRelax.ThermalArrays)
    return _temperature2center!(thermal)
end

function JR2D.vertex2center!(center::T, vertex::T) where {T<:ROCArray}
    return vertex2center!(center, vertex)
end

function JR2D.center2vertex!(vertex::T, center::T) where {T<:ROCArray}
    return center2vertex!(vertex, center)
end

function JR2D.center2vertex!(
    vertex_yz::T, vertex_xz::T, vertex_xy::T, center_yz::T, center_xz::T, center_xy::T
) where {T<:ROCArray}
    return center2vertex!(vertex_yz, vertex_xz, vertex_xy, center_yz, center_xz, center_xy)
end

function JR2D.velocity2vertex!(
    Vx_v::ROCArray, Vy_v::ROCArray, Vx::ROCArray, Vy::ROCArray; ghost_nodes=true
)
    velocity2vertex!(Vx_v, Vy_v, Vx, Vy; ghost_nodes=ghost_nodes)
    return nothing
end

function JR2D.velocity2displacement!(
    ::AMDGPUBackendTrait, stokes::JustRelax.StokesArrays, dt
)
    return _velocity2displacement!(stokes, dt)
end

function velocity2displacement!(::AMDGPUBackendTrait, stokes::JustRelax.StokesArrays, dt)
    return _velocity2displacement!(stokes, dt)
end

function JR2D.displacement2velocity!(
    ::AMDGPUBackendTrait, stokes::JustRelax.StokesArrays, dt
)
    return _displacement2velocity!(stokes, dt)
end

function displacement2velocity!(::AMDGPUBackendTrait, stokes::JustRelax.StokesArrays, dt)
    return _displacement2velocity!(stokes, dt)
end

# Solvers
function JR2D.solve!(::AMDGPUBackendTrait, stokes, args...; kwargs)
    return _solve!(stokes, args...; kwargs...)
end

function JR2D.heatdiffusion_PT!(::AMDGPUBackendTrait, thermal, args...; kwargs)
    return _heatdiffusion_PT!(thermal, args...; kwargs...)
end

# Utils
function JR2D.compute_dt(::AMDGPUBackendTrait, S::JustRelax.StokesArrays, args...)
    return _compute_dt(S, args...)
end

# Subgrid diffusion

function JR2D.subgrid_characteristic_time!(
    subgrid_arrays,
    particles,
    dt₀::ROCArray,
    phases::JustRelax.PhaseRatio,
    rheology,
    thermal::JustRelax.ThermalArrays,
    stokes::JustRelax.StokesArrays,
    xci,
    di,
)
    ni = size(stokes.P)
    @parallel (@idx ni) subgrid_characteristic_time!(
        dt₀, phases.center, rheology, thermal.Tc, stokes.P, di
    )
    return nothing
end

function JR2D.subgrid_characteristic_time!(
    subgrid_arrays,
    particles,
    dt₀::ROCArray,
    phases::AbstractArray{Int,N},
    rheology,
    thermal::JustRelax.ThermalArrays,
    stokes::JustRelax.StokesArrays,
    xci,
    di,
) where {N}
    ni = size(stokes.P)
    @parallel (@idx ni) subgrid_characteristic_time!(
        dt₀, phases, rheology, thermal.Tc, stokes.P, di
    )
    return nothing
end

# shear heating

function JR2D.compute_shear_heating!(::AMDGPUBackendTrait, thermal, stokes, rheology, dt)
    ni = size(thermal.shear_heating)
    @parallel (ni) compute_shear_heating_kernel!(
        thermal.shear_heating,
        @tensor_center(stokes.τ),
        @tensor_center(stokes.τ_o),
        @strain(stokes),
        rheology,
        dt,
    )
    return nothing
end

function JR2D.compute_shear_heating!(
    ::AMDGPUBackendTrait, thermal, stokes, phase_ratios::JustRelax.PhaseRatio, rheology, dt
)
    ni = size(thermal.shear_heating)
    @parallel (@idx ni) compute_shear_heating_kernel!(
        thermal.shear_heating,
        @tensor_center(stokes.τ),
        @tensor_center(stokes.τ_o),
        @strain(stokes),
        phase_ratios.center,
        rheology,
        dt,
    )
    return nothing
end

end
