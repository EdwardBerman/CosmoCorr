module kdtree 

include("metrics.jl")
using .metrics

export Galaxy, KD_Galaxy_Tree, Galaxy_Circle, append_left!, append_right!, initialize_circles, split_galaxy_cells!, populate, get_leaves, collect_leaves

using AbstractTrees
using Statistics
using Base.Threads

struct Galaxy 
    ra::Float64
    dec::Float64
    corr1::Any
    corr2::Any
end

mutable struct Galaxy_Circle{T, r, g}
    center::Vector{T}
    radius::r
    galaxies::Vector{g}
    index::Int
    split::Bool
end

mutable struct KD_Galaxy_Tree
    root::Galaxy_Circle
    left::Union{KD_Galaxy_Tree, Nothing}
    right::Union{KD_Galaxy_Tree, Nothing}
end

function append_left!(tree::KD_Galaxy_Tree, node::KD_Galaxy_Tree)
    if tree.left === nothing
        tree.left = node
    else
        append_left!(tree.left, node)
    end
end

function append_right!(tree::KD_Galaxy_Tree, node::KD_Galaxy_Tree)
    if tree.right === nothing
        tree.right = node
    else
        append_right!(tree.right, node)
    end
end


function get_leaves(node::KD_Galaxy_Tree)::Vector{KD_Galaxy_Tree}
    leaves = Vector{KD_Galaxy_Tree}()
    collect_leaves(node, leaves)
    return leaves
end

function collect_leaves(node::Union{KD_Galaxy_Tree, Nothing}, leaves::Vector{KD_Galaxy_Tree})
    if node === nothing
        return
    elseif node.left === nothing && node.right === nothing
        push!(leaves, node)
    else
        collect_leaves(node.left, leaves)
        collect_leaves(node.right, leaves)
    end
end

function initialize_circles(galaxies::Vector{Galaxy}; sky_metric=Vincenty_Formula)
    ra_list = [galaxy.ra for galaxy in galaxies]
    dec_list = [galaxy.dec for galaxy in galaxies]
    ra_extent = maximum(ra_list) - minimum(ra_list)
    dec_extent = maximum(dec_list) - minimum(dec_list)
    if ra_extent > dec_extent
        println("Splitting on RA...")
        ra_median = median(ra_list)
        left_galaxies = [galaxy for galaxy in galaxies if galaxy.ra < ra_median]
        right_galaxies = [galaxy for galaxy in galaxies if galaxy.ra >= ra_median]
        left_average_position_ra = mean([galaxy.ra for galaxy in left_galaxies])
        left_average_position_dec = mean([galaxy.dec for galaxy in left_galaxies])
        right_average_position_ra = mean([galaxy.ra for galaxy in right_galaxies])
        right_average_position_dec = mean([galaxy.dec for galaxy in right_galaxies])
        max_distance_left = maximum([sky_metric([left_average_position_ra, left_average_position_dec], [galaxy.ra, galaxy.dec]) for galaxy in left_galaxies])
        max_distance_right = maximum([sky_metric([right_average_position_ra, right_average_position_dec], [galaxy.ra, galaxy.dec]) for galaxy in right_galaxies])
        left_circle = KD_Galaxy_Tree(Galaxy_Circle([left_average_position_ra, left_average_position_dec], max_distance_left, left_galaxies, 0, false), nothing, nothing)
        right_circle = KD_Galaxy_Tree(Galaxy_Circle([right_average_position_ra, right_average_position_dec], max_distance_right, right_galaxies, 0, false), nothing, nothing)
    else
        println("Splitting on DEC...")
        dec_median = median(dec_list)
        left_galaxies = [galaxy for galaxy in galaxies if galaxy.dec < dec_median]
        right_galaxies = [galaxy for galaxy in galaxies if galaxy.dec >= dec_median]
        left_average_position_ra = mean([galaxy.ra for galaxy in left_galaxies])
        left_average_position_dec = mean([galaxy.dec for galaxy in left_galaxies])
        right_average_position_ra = mean([galaxy.ra for galaxy in right_galaxies])
        right_average_position_dec = mean([galaxy.dec for galaxy in right_galaxies])
        max_distance_left = maximum([sky_metric([left_average_position_ra, left_average_position_dec], [galaxy.ra, galaxy.dec]) for galaxy in left_galaxies])
        max_distance_right = maximum([sky_metric([right_average_position_ra, right_average_position_dec], [galaxy.ra, galaxy.dec]) for galaxy in right_galaxies])
        left_circle = KD_Galaxy_Tree(Galaxy_Circle([left_average_position_ra, left_average_position_dec], max_distance_left, left_galaxies, 2, false), nothing, nothing)
        right_circle = KD_Galaxy_Tree(Galaxy_Circle([right_average_position_ra, right_average_position_dec], max_distance_right, right_galaxies, 1, false), nothing, nothing)
    end
    inititial_ra = mean(ra_list)
    inititial_dec = mean(dec_list)
    initial_radius = maximum([sky_metric([inititial_ra, inititial_dec], [galaxy.ra, galaxy.dec]) for galaxy in galaxies])
    initial_circle = KD_Galaxy_Tree(Galaxy_Circle([inititial_ra, inititial_dec], initial_radius, galaxies, 0, false), left_circle, right_circle)

    return initial_circle
end

function split_galaxy_cells!(leaves::Vector{KD_Galaxy_Tree}, θ_bins::Vector{Float64}, count::Int64; sky_metric=Vincenty_Formula)
    galaxy_circles = [leaf.root for leaf in leaves]
    # circle_ra = [circle.center[1] for circle in galaxy_circles]
    # circle_dec = [circle.center[2] for circle in galaxy_circles]
    #distance_matrix = build_distance_matrix(circle_ra, circle_dec, metric=sky_metric) 
    #galaxy_radius_adj = [j < i ? galaxy_circles[i].radius + galaxy_circles[j].radius : 0 for i in 1:length(galaxy_circles), j in 1:length(galaxy_circles)]
    #comparison_matrix = galaxy_radius_adj ./ distance_matrix
    #@assert size(distance_matrix) == size(galaxy_radius_adj)
    #split_matrix = comparison_matrix .> b
    b = log10(θ_bins[length(θ_bins)] - θ_bins[1])/length(θ_bins)

    @threads for i in 1:length(galaxy_circles)
        for j in 1:length(galaxy_circles)
            split_condition_1 = j < i
            circles_radii = galaxy_circles[i].radius + galaxy_circles[j].radius
            center_distance = sky_metric([galaxy_circles[i].center[1], galaxy_circles[i].center[2]], [galaxy_circles[j].center[1], galaxy_circles[j].center[2]])
            center_distance_bin = findfirst(θ_bins .> center_distance)
            radii_distance_bin = findfirst(θ_bins .> circles_radii + center_distance)
            if radii_distance_bin === nothing
                radii_distance_bin = length(θ_bins)
            end
            if center_distance_bin === nothing
                center_distance_bin = length(θ_bins)
            end
            Δθ_bins = radii_distance_bin - center_distance_bin
            if Δθ_bins > 1 && length(galaxy_circles[i].galaxies) > 1 && length(galaxy_circles[j].galaxies) > 1 # replace 1 with bin slop?
                leaves[i].root.split = true
                leaves[j].root.split = true
            elseif Δθ_bins > 1 && length(galaxy_circles[i].galaxies) == 1 && length(galaxy_circles[j].galaxies) > 1
                leaves[j].root.split = true
            elseif Δθ_bins > 1 && length(galaxy_circles[i].galaxies) > 1 && length(galaxy_circles[j].galaxies) == 1
                leaves[i].root.split = true
            end
        end
    end
        
    split_array = [leaf.root.split for leaf in leaves]
    for i in 1:length(split_array)
        if split_array[i] == true
            split_array[i] = 1 
        else
            split_array[i] = 0
        end
    end

    if sum(split_array) == 0
        println("No more splits possible.")
        return 0, count
    else
        @threads for leaf in leaves
            if leaf.root.split == true
                circle = leaf.root
                ra_list = [galaxy.ra for galaxy in circle.galaxies]
                dec_list = [galaxy.dec for galaxy in circle.galaxies]
                ra_extent = maximum(ra_list) - minimum(ra_list)
                dec_extent = maximum(dec_list) - minimum(dec_list)
                if length(circle.galaxies) == 1
                    leaf.root.split = false
                elseif ra_extent > dec_extent
                    ra_median = median(ra_list)
                    left_galaxies = [galaxy for galaxy in circle.galaxies if galaxy.ra < ra_median]
                    right_galaxies = [galaxy for galaxy in circle.galaxies if galaxy.ra >= ra_median]
                    left_average_position_ra = mean([galaxy.ra for galaxy in left_galaxies])
                    left_average_position_dec = mean([galaxy.dec for galaxy in left_galaxies])
                    right_average_position_ra = mean([galaxy.ra for galaxy in right_galaxies])
                    right_average_position_dec = mean([galaxy.dec for galaxy in right_galaxies])
                    max_distance_left = maximum([sky_metric([left_average_position_ra, left_average_position_dec], [galaxy.ra, galaxy.dec]) for galaxy in left_galaxies])
                    max_distance_right = maximum([sky_metric([right_average_position_ra, right_average_position_dec], [galaxy.ra, galaxy.dec]) for galaxy in right_galaxies])
                    left_circle = KD_Galaxy_Tree(Galaxy_Circle([left_average_position_ra, left_average_position_dec], max_distance_left, left_galaxies, count, false), nothing, nothing)
                    right_circle = KD_Galaxy_Tree(Galaxy_Circle([right_average_position_ra, right_average_position_dec], max_distance_right, right_galaxies, count + 1, false), nothing, nothing)
                    append_left!(leaf, left_circle)
                    append_right!(leaf, right_circle)
                    count += 2
                else
                    dec_median = median(dec_list)
                    left_galaxies = [galaxy for galaxy in circle.galaxies if galaxy.dec < dec_median]
                    right_galaxies = [galaxy for galaxy in circle.galaxies if galaxy.dec >= dec_median]
                    left_average_position_ra = mean([galaxy.ra for galaxy in left_galaxies])
                    left_average_position_dec = mean([galaxy.dec for galaxy in left_galaxies])
                    right_average_position_ra = mean([galaxy.ra for galaxy in right_galaxies])
                    right_average_position_dec = mean([galaxy.dec for galaxy in right_galaxies])
                    max_distance_left = maximum([sky_metric([left_average_position_ra, left_average_position_dec], [galaxy.ra, galaxy.dec]) for galaxy in left_galaxies])
                    max_distance_right = maximum([sky_metric([right_average_position_ra, right_average_position_dec], [galaxy.ra, galaxy.dec]) for galaxy in right_galaxies])
                    left_circle = KD_Galaxy_Tree(Galaxy_Circle([left_average_position_ra, left_average_position_dec], max_distance_left, left_galaxies, count, false), nothing, nothing)
                    right_circle = KD_Galaxy_Tree(Galaxy_Circle([right_average_position_ra, right_average_position_dec], max_distance_right, right_galaxies, count + 1, false), nothing, nothing)
                    append_left!(leaf, left_circle)
                    append_right!(leaf, right_circle)
                    count += 2
                end
            end
        end
        return 1, count
    end
end

function populate(galaxies::Vector{Galaxy}, θ_bins::Vector{Float64}; sky_metric=Vincenty_Formula, splitter=split_galaxy_cells!, max_depth=100)
    tree = initialize_circles(galaxies, sky_metric=sky_metric)
    
    split_number = 1
    continue_splitting = (split_number != 0)
    count = 3
    iteration = 1
    while continue_splitting 
        leaves = get_leaves(tree)
        if iteration%5 == 0 && iteration < 100
            println("Iteration: ", iteration,"...")
            println("Number of leaves: ", length(leaves))
        end
        split_number, count = splitter(leaves, θ_bins, count, sky_metric=sky_metric)
        continue_splitting = (split_number != 0)
        iteration += 1
        if iteration > max_depth
            println("Max depth reached.")
            break
        end
    end
    return tree
end


end
