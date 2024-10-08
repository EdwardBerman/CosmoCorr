using SciMLSensitivity
using DelimitedFiles, Plots
using OrdinaryDiffEq, Zygote
using SciMLSensitivity
using DelimitedFiles, Plots
using OrdinaryDiffEq, Zygote
using Statistics
using Random
using Distributions

Lx, Ly = 50.0, 50.0
x = 0.0:0.1:Lx  # Grid for x (RA)
y = 0.0:0.1:Ly  # Grid for y (Dec)
dx = x[2] - x[1]
dy = y[2] - y[1]
Nx = size(x)
Ny = size(y)

num_walkers = 100
walker_positions_x = rand(num_walkers) .* Lx
walker_positions_y = rand(num_walkers) .* Ly

u0_x = exp.(-100*(x .- Lx/2).^2 / (2.0))
u0_y = exp.(-100*(y .- Ly/2).^2 / (2.0))

## Problem Parameters
p = [1.0, 1.0]  # Diffusion coefficients for x and y
const xtrs = [dx, dy, Nx, Ny]  # Extra parameters
dt = 0.40 * min(dx^2, dy^2)  # CFL condition
t0, tMax = 0.0, 1000 * dt
tspan = (t0, tMax)
t = t0:dt:tMax;

## Definition of Auxiliary functions for 2D diffusion
function d2dx(u, dx)
    return [zero(eltype(u));
            (@view(u[3:end]) .- 2.0 .* @view(u[2:(end - 1)]) .+ @view(u[1:(end - 2)])) ./
            (dx^2)
            zero(eltype(u))]
end

function d2dy(u, dy)
    return [zero(eltype(u));
            (@view(u[3:end]) .- 2.0 .* @view(u[2:(end - 1)]) .+ @view(u[1:(end - 2)])) ./
            (dy^2)
            zero(eltype(u))]
end

function heat2d(u_x, u_y, p, t, xtrs)
    a1_x, a1_y = p  # Diffusion coefficients for x and y
    dx, dy, Nx, Ny = xtrs
    
    dudx2 = a1_x .* d2dx(u_x, dx)
    dudy2 = a1_y .* d2dy(u_y, dy)
    
    return dudx2, dudy2
end

heat_closure(u_x, u_y, p, t) = heat2d(u_x, u_y, p, t, xtrs)

function scale_to_360(data)
    x_min = minimum(data)
    x_max = maximum(data)
    (data .- x_min) ./ (x_max - x_min) .* 360
end

function catalog_generator(p)
    prob_x = ODEProblem((u,p,t)->heat_closure(u,u,p,t)[1], u0_x, tspan, p)
    prob_y = ODEProblem((u,p,t)->heat_closure(u,u,p,t)[2], u0_y, tspan, p)

    sol_x = solve(prob_x, Tsit5(), dt = dt, saveat = t);
    sol_y = solve(prob_y, Tsit5(), dt = dt, saveat = t);

    arr_sol_x = Array(sol_x)
    arr_sol_y = Array(sol_y)

    final_positions_x = sol_x[end]  # Access the final state directly
    final_positions_y = sol_y[end]  # Access the final state directly
    
    scaled_positions_x = scale_to_360(final_positions_x)
    scaled_positions_y = scale_to_360(final_positions_y)

    samples = hcat(scaled_positions_x, scaled_positions_y)
    return samples
end

#println(catalog_generator(p))
println(gradient(catalog_generator, p))
#println(grad_diffusion_positions)
