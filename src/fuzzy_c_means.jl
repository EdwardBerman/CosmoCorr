using Zygote
using UnicodePlots
using Random

function Vincenty_Formula(coord1::Vector{Float64}, coord2::Vector{Float64})
    ϕ1, λ1 = coord1
    ϕ2, λ2 = coord2
    ϕ1 *= π / 180
    λ1 *= π / 180
    ϕ2 *= π / 180
    λ2 *= π / 180
    
    Δλ = λ2 - λ1
    c1 = (cos(ϕ2)*sin(Δλ))^2
    c2 = (cos(ϕ1)*sin(ϕ2) - sin(ϕ1)*cos(ϕ2)*cos(Δλ))^2
    c3 = sin(ϕ1)*sin(ϕ2) + cos(ϕ1)*cos(ϕ2)*cos(Δλ)
    y = sqrt(c1 + c2)
    x = c3
    Δσ = atan(y, x)
    return Δσ * (180 / π) * 60
end

function Vincenty_Formula(coord1::Tuple{Float64, Float64}, coord2::Tuple{Float64, Float64})
    ϕ1, λ1 = coord1
    ϕ2, λ2 = coord2
    ϕ1 *= π / 180
    λ1 *= π / 180
    ϕ2 *= π / 180
    λ2 *= π / 180
    
    Δλ = λ2 - λ1
    c1 = (cos(ϕ2)*sin(Δλ))^2
    c2 = (cos(ϕ1)*sin(ϕ2) - sin(ϕ1)*cos(ϕ2)*cos(Δλ))^2
    c3 = sin(ϕ1)*sin(ϕ2) + cos(ϕ1)*cos(ϕ2)*cos(Δλ)
    y = sqrt(c1 + c2)
    x = c3
    Δσ = atan(y, x)
    return Δσ * (180 / π) * 60 
end

function calculate_weights(current_weights, data, centers, fuzziness, dist_metric=Vincenty_Formula)
    pow = 2.0/(fuzziness-1)
    nrows, ncols = size(current_weights)
    ϵ = 1e-10
    dists = [dist_metric(data[:,i], centers[:,j]) for i in 1:size(data,2), j in 1:size(centers,2)]
    weights = [1.0 / sum(( (dists[i,j] + ϵ) /(dists[i,k] + ϵ))^pow for k in 1:ncols) for i in 1:nrows, j in 1:ncols]
    return weights
end

function calculate_centers(current_centers, data, weights, fuzziness)
    nrows, ncols = size(weights)
    centers = hcat([sum(weights[i,j]^fuzziness * data[:,i] for i in 1:nrows) / sum(weights[i,j]^fuzziness for i in 1:nrows) for j in 1:ncols]...)
    return centers
end

function fuzzy_c_means(data, n_clusters, initial_centers, initial_weights, fuzziness, dist_metric=Vincenty_Formula, tol=1e-6, max_iter=1000)
    centers = initial_centers
    weights = initial_weights
    current_iteration = 0
    while current_iteration < max_iter
        old_centers = copy(centers)
        old_weights = copy(weights)
        centers = calculate_centers(centers, data, weights, fuzziness)
        weights = calculate_weights(weights, data, centers, fuzziness, dist_metric)
        current_iteration += 1
        if sum(abs2, weights - old_weights) < tol
            break
        end
    end
    return centers, weights, current_iteration
end

function weighted_average(quantity, weights)
    weighted_sum = quantity' * weights  
    sum_weights = sum(weights, dims=1)
    weighted_average = weighted_sum ./ sum_weights
    return weighted_average
end

data = hcat([90 .* rand(2) for i in 1:100]...)  
shear_one = rand(100)
shear_two = rand(100)
n_clusters = 3
nrows, ncols = size(data)
initial_centers = rand(nrows, n_clusters)
initial_weights = rand(ncols, n_clusters)
centers, weights, iterations = fuzzy_c_means(data, n_clusters, initial_centers, initial_weights, 2.0)
@info "Converged in $iterations iterations"

weighted_shear_one = weighted_average(shear_one, weights)
weighted_shear_two = weighted_average(shear_two, weights)

fuzzy_galaxies = [[centers[1,i], centers[2,i], weighted_shear_one[i], weighted_shear_two[i]] for i in 1:n_clusters]
fuzzy_distances = [(fuzzy_galaxies[i], 
                    fuzzy_galaxies[j], 
                    Vincenty_Formula(fuzzy_galaxies[i][1:2], fuzzy_galaxies[j][1:2])) for i in 1:n_clusters, j in 1:n_clusters if i < j] 

function combine_vectors_to_matrix(vec1, datapoint, vec2)
    result = vcat(vec1, datapoint, vec2)
    return result
end

function filter_in_range(matrix::AbstractMatrix{T}, min_val::T, max_val::T) where T
    return map(x -> (x > min_val && x <= max_val) ? x : zero(T), matrix)
end

function fuzzy_shear_estimator(fuzzy_distance)
    return mean(dot(fuzzy_distance[1][3], fuzzy_distance[2][4]) + dot(fuzzy_distance[1][4], fuzzy_distances[2][3]))
end

function correlator(ra, dec, quantity_one, quantity_two, nclusters, initial_centers, initial_weights, fuzziness=2.0, dist_metric=Vincenty_Formula, tol=1e-6, max_iter=1000)
    data = hcat([ra, dec]...)
    x = cos.(dec) .* cos.(ra)
    y = cos.(dec) .* sin.(ra) # normalize x y z?
    ϕ = [atan(y[i], x[i]) for i in 1:size(x,1)]

    centers, weights, iterations = fuzzy_c_means(data, nclusters, initial_centers, initial_weights, fuzziness, dist_metric, tol, max_iter)
    weighted_shear_one = [weighted_average(quantity_one[1], weights), weighted_average(quantity_one[2], weights)]
    weighted_shear_two = [weighted_average(quantity_two[1], weights), weighted_average(quantity_two[2], weights)]
    fuzzy_galaxies = [[centers[1,i], centers[2,i], weighted_shear_one[i], weighted_shear_two[i]] for i in 1:nclusters]
    fuzzy_distances = [(fuzzy_galaxies[i], 
                        fuzzy_galaxies[j], 
                        Vincenty_Formula(fuzzy_galaxies[i][1:2], fuzzy_galaxies[j][1:2])) for i in 1:nclusters, j in 1:nclusters if i < j]
    #binned_fuzzy_distances = ...
    correlations = [fuzzy_shear_estimator(fuzzy_distance) for fuzzy_distance in binned_fuzzy_distances]
end

@time begin
    grad_data = Zygote.gradient(data -> sum(fuzzy_c_means(data, n_clusters, initial_centers, initial_weights, 2.0)[1]), data)
    println("Gradient with respect to data", grad_data)
    println(size(grad_data[1]))
    println(heatmap(grad_data[1]', title="Gradient with respect to data", xlabel="Longitude", ylabel="Latitude", colormap=:coolwarm))
end
#@time begin
 #   grad_data = Zygote.gradient(data -> sum(fuzzy_c_means(data, n_clusters, initial_centers, initial_weights, 2.0)[2]), data)
  #  println("Gradient with respect to data", grad_data)
#end



#println("Gradients with respect to data for centers: ", grads_one)
#println("Gradients with respect to data for weights: ", grads_two)

    #grads_one = gradient(x -> sum(fuzzy_c_means(data, n_clusters, initial_centers, initial_weights, 2.0)[1]), data)
    #grads_two = gradient(x -> sum(fuzzy_c_means(data, n_clusters, initial_centers, initial_weights, 2.0)[2]), data)
#println("Gradient with respect to data[$m, $n] for centers: ", grad_center_single)
#println("Gradient with respect to data[$m, $n] for weights: ", grad_weight_single)

#grads = gradient(x -> sum(fuzzy_c_means(data, n_clusters, initial_centers, initial_weights, 2.0)[1]), data)
#grads = gradient(x -> sum(fuzzy_c_means(data, n_clusters, initial_centers, initial_weights, 2.0)[2]), data)

println(scatterplot(data[1,:], data[2,:], title="Data Points", xlabel="Longitude", ylabel="Latitude"))
println(scatterplot(centers[1,:], centers[2,:], title="Cluster Centers", xlabel="Longitude", ylabel="Latitude"))
println(heatmap(weights', title="Weights", xlabel="Data Point", ylabel="Cluster", colormap=:coolwarm))
println(heatmap(weights', title="Weights", xlabel="Data Point", ylabel="Cluster", colormap=:cool))
#println([sum(weights[i,:]) for i in 1:size(weights,1)])


#=
# Define the range filtering function
function filter_in_range(matrix::AbstractMatrix{T}, min_val::T, max_val::T) where T
    return map(x -> (x > min_val && x <= max_val) ? x : zero(T), matrix)
end

function sum_intervals(matrix::AbstractMatrix{T}) where T
    return [sum(filter_in_range(matrix, min_val, min_val + 0.1)) for min_val in 0:0.1:0.9]
end

# Example usage
matrix = rand(3, 3)  # A 3x3 random matrix

# Compute the sum over all intervals
interval_sums = sum_intervals(matrix)
println(interval_sums)

# Compute the Jacobian with respect to the input matrix
jac = Zygote.jacobian(sum_intervals, matrix)

# Output
println("Original Matrix:")
println(matrix)
println("\nSums for Each Interval:")
println(interval_sums)
println("\nJacobian of the Sums w.r.t. the Input Matrix:")
println(jac[1])
=#
