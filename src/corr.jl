module astrocorr
    include("metrics.jl")
    include("queue_tree.jl")
    include("stack_tree.jl")
    include("kmean.jl")
    include("estimators.jl")
    include("fuzzy_c_means.jl")
    include("probabilistic_fuzzy.jl")

    using .metrics
    using .queue_tree 
    using .stack_tree
    using .kmc
    using .estimators
    using .fuzzy
    using .probabilistic_fuzzy

    export corr, naivecorr, clustercorr, treecorr_queue, corr_metric_default_scalar_scalar, corr_metric_default_position_position, Position_RA_DEC, landy_szalay_estimator, DD, DR, RR, interpolate_to_common_bins_spline, Galaxy_Catalog, Galaxy, KD_Galaxy_Tree, Galaxy_Circle, append_left!, append_right!, initialize_circles, split_galaxy_cells!, populate, get_leaves, collect_leaves, kmeans_clustering, build_distance_matrix, metric_dict, Vincenty_Formula, Vincenty, corr_metric_default_vector_vector, ξ_plus, build_distance_matrix_subblock, shear, corr_metric_shear_minus, corr_metric_default_shear_shear, fuzzy_c_means, fuzzy_shear_estimator, fuzzy_correlator, fuzzy_shear, weighted_average, calculate_direction, calculate_weights, calculate_centers, kmeans_plusplus_weighted_initialization_vincenty, probabilistic_correlator

    using LinearAlgebra
    using Base.Threads
    using Statistics
    using Clustering
    using Distances
    using DataFrames
    using Interpolations
    using Base.Iterators: product
    using Base.Iterators: partition
    using UnicodePlots

    struct Galaxy_Catalog
        ra::Vector{Float64}
        dec::Vector{Float64}
        corr1::Vector{Any}
        corr2::Vector{Any}
    end

    struct shear
        tan_cross::Vector{Float64}
    end

    struct Position_RA_DEC
        ra::Float64
        dec::Float64
        value::String
        Position_RA_DEC(ra::Float64, dec::Float64, value::String) = begin
            if value == "DATA" || value == "RANDOM"
                new(ra, dec, value)
            else
                error("value must be either 'DATA' or 'RANDOM'")
            end
        end
    end

    function treecorr_queue(ra, 
            dec, 
            corr1, 
            corr2, 
            θ_min, 
            number_bins, 
            θ_max; 
            cluster_factor=0.25, 
            spacing=log, 
            sky_metric=Vincenty_Formula, 
            kmeans_metric=Vincenty,
            corr_metric=corr_metric_default, 
            splitter=split_galaxy_cells!,
            max_depth=3,
            bin_slop=nothing,
            verbose=false)
        @assert length(ra) == length(dec) == length(corr1) == length(corr2) "ra, dec, corr1, and corr2 must be the same length"
        
        if verbose
            scatterplot_galaxies = scatterplot(ra, dec, title="Object Positions", xlabel="RA", ylabel="DEC")
            densityplot_galaxies = densityplot(ra, dec, title="Object Density", xlabel="RA", ylabel="DEC")
            println(scatterplot_galaxies)
            println(densityplot_galaxies)
            println("Tree Correlation")
        end

        sky_metric = sky_metric
        galaxies = [Galaxy(ra[i], dec[i], corr1[i], corr2[i]) for i in 1:length(ra)]
        
        θ_bins = range(θ_min, stop=θ_max, length=number_bins)
        
        if spacing == log
            if verbose
                println("Logarithmic spacing")
            end
            θ_bins = 10 .^ range(log10(θ_min), log10(θ_max), length=number_bins)
        end

        b = Δ_ln_d = (log(θ_max) - log(θ_min) )/ number_bins
        bin_size = b

        if verbose
            println("Bin size: ", bin_size)
            println("Populating KDTree")
        end

        tree = populate(galaxies, θ_bins, bin_size, sky_metric=sky_metric, splitter=splitter, max_depth=max_depth, bin_slop=bin_slop) # b = Δ (ln d) 
        
        if verbose
            println("Populated KDTree")
        end
        
        leafs = get_leaves(tree)
        ra_circles = [leaf.root.center[1] for leaf in leafs]
        dec_circles = [leaf.root.center[2] for leaf in leafs]
        n = length(ra_circles)

        if verbose
            scatterplot_clusters = scatterplot(ra_circles, dec_circles, title="Cluster Positions", xlabel="RA", ylabel="DEC")
            densityplot_clusters = densityplot(ra_circles, dec_circles, title="Cluster Density", xlabel="RA", ylabel="DEC")
            println(scatterplot_clusters)
            println(densityplot_clusters)
            println("Number of circles: ", n)
            println("Computing Distance Matrix")
        end

        distance_matrix = build_distance_matrix(ra_circles, dec_circles, metric=sky_metric)

        if verbose
            println("Distance Matrix complete")
        end

        indices = [(i, j) for i in 1:n, j in 1:n if j < i]
        distance_vector = [distance_matrix[i, j] for (i, j) in indices]
        
        θ_bin_assignments = zeros(length(distance_vector))
        for i in 1:length(distance_vector)
            for j in 1:length(θ_bins)
                if distance_vector[i] < θ_bins[j] && distance_vector[i] > θ_min
                    θ_bin_assignments[i] = j
                    break
                end
            end
        end
        
        if verbose
            println("Assigning data points to θ bins")
        end

        empty_bins = 0
        for i in 1:number_bins
            bin = findall(θ_bin_assignments .== i)
            if isempty(bin)
                empty_bins += 1
            end
        end

        println("Empty bins: ", empty_bins)

        ψ_array = zeros(number_bins - empty_bins, 5)

        Threads.@threads for i in 1:(number_bins - empty_bins)
            bin = findall(θ_bin_assignments .== i)
            if !isempty(bin)
                min_distance = minimum(distance_vector[bin])
                max_distance = maximum(distance_vector[bin])
                mean_distance = mean(distance_vector[bin])
                bin_indices = [indices[k] for k in bin]

                corr1_values = []
                corr2_values = []

                corr1_reverse_values = []
                corr2_reverse_values = []

                for (i, j) in bin_indices
                    for galaxy_i in leafs[i].root.galaxies
                        for galaxy_j in leafs[j].root.galaxies
                            append!(corr1_values, [galaxy_i.corr1])
                            append!(corr2_values, [galaxy_j.corr2])
                            append!(corr1_reverse_values, [galaxy_j.corr1])
                            append!(corr2_reverse_values, [galaxy_i.corr2])
                        end
                    end
                end

                ψ_bin = corr_metric(corr1_values, corr2_values, corr1_reverse_values, corr2_reverse_values)
                ψ_array[i,:] = [i, min_distance, max_distance, mean_distance, ψ_bin]
            end
        end
        
        if verbose
            println("Assigned data points to θ bins")
            println(ψ_array)
        end
        
        ψ_θ = zeros(2, number_bins - empty_bins) 
        for i in 1:(number_bins - empty_bins)
            ψ_θ[1,i] = ψ_array[i, 4]
            ψ_θ[2,i] = ψ_array[i, 5]
        end
        ψ_θ = ψ_θ[:, sortperm(ψ_θ[1,:])]
        
        if verbose
            plt = lineplot(log10.(ψ_θ[1,:]), log10.(abs.(ψ_θ[2,:])), title="Correlation Function", name="Correlation Function", xlabel="log10(θ)", ylabel="log10(ξ(θ))")
            println(plt)
        end
       
        return ψ_θ
    end
    
    function treecorr_stack(ra, 
            dec, 
            corr1, 
            corr2, 
            θ_min, 
            number_bins, 
            θ_max; 
            cluster_factor=0.25, 
            spacing=log, 
            sky_metric=Vincenty_Formula, 
            kmeans_metric=Vincenty,
            corr_metric=corr_metric_default, 
            splitter=split_galaxy_cells!,
            max_depth=3,
            bin_slop=nothing,
            verbose=false)
        @assert length(ra) == length(dec) == length(corr1) == length(corr2) "ra, dec, corr1, and corr2 must be the same length"
        
        if verbose
            scatterplot_galaxies = scatterplot(ra, dec, title="Object Positions", xlabel="RA", ylabel="DEC")
            densityplot_galaxies = densityplot(ra, dec, title="Object Density", xlabel="RA", ylabel="DEC")
            println(scatterplot_galaxies)
            println(densityplot_galaxies)
            println("Tree Correlation")
        end

        sky_metric = sky_metric
        galaxies = [Galaxy(ra[i], dec[i], corr1[i], corr2[i]) for i in 1:length(ra)]
        
        θ_bins = range(θ_min, stop=θ_max, length=number_bins)
        
        if spacing == log
            if verbose
                println("Logarithmic spacing")
            end
            θ_bins = 10 .^ range(log10(θ_min), log10(θ_max), length=number_bins)
        end

        b = Δ_ln_d = (log(θ_max) - log(θ_min) )/ number_bins
        bin_size = b

        if verbose
            println("Bin size: ", bin_size)
            println("Populating KDTree")
        end

        tree = populate(galaxies, θ_bins, bin_size, sky_metric=sky_metric, splitter=splitter, max_depth=max_depth, bin_slop=bin_slop) # b = Δ (ln d) 
        
        if verbose
            println("Populated KDTree")
        end
        
        leafs = get_leaves(tree)
        ra_circles = [leaf.root.center[1] for leaf in leafs]
        dec_circles = [leaf.root.center[2] for leaf in leafs]
        n = length(ra_circles)

        if verbose
            scatterplot_clusters = scatterplot(ra_circles, dec_circles, title="Cluster Positions", xlabel="RA", ylabel="DEC")
            densityplot_clusters = densityplot(ra_circles, dec_circles, title="Cluster Density", xlabel="RA", ylabel="DEC")
            println(scatterplot_clusters)
            println(densityplot_clusters)
            println("Number of circles: ", n)
            println("Computing Distance Matrix")
        end

        distance_matrix = build_distance_matrix(ra_circles, dec_circles, metric=sky_metric)

        if verbose
            println("Distance Matrix complete")
        end

        indices = [(i, j) for i in 1:n, j in 1:n if j < i]
        distance_vector = [distance_matrix[i, j] for (i, j) in indices]
        
        θ_bin_assignments = zeros(length(distance_vector))
        for i in 1:length(distance_vector)
            for j in 1:length(θ_bins)
                if distance_vector[i] < θ_bins[j] && distance_vector[i] > θ_min
                    θ_bin_assignments[i] = j
                    break
                end
            end
        end
        
        if verbose
            println("Assigning data points to θ bins")
        end

        empty_bins = 0
        for i in 1:number_bins
            bin = findall(θ_bin_assignments .== i)
            if isempty(bin)
                empty_bins += 1
            end
        end

        println("Empty bins: ", empty_bins)

        ψ_array = zeros(number_bins - empty_bins, 5)

        Threads.@threads for i in 1:(number_bins - empty_bins)
            bin = findall(θ_bin_assignments .== i)
            if !isempty(bin)
                min_distance = minimum(distance_vector[bin])
                max_distance = maximum(distance_vector[bin])
                mean_distance = mean(distance_vector[bin])
                bin_indices = [indices[k] for k in bin]

                corr1_values = []
                corr2_values = []

                corr1_reverse_values = []
                corr2_reverse_values = []

                for (i, j) in bin_indices
                    for galaxy_i in leafs[i].root.galaxies
                        for galaxy_j in leafs[j].root.galaxies
                            append!(corr1_values, [galaxy_i.corr1])
                            append!(corr2_values, [galaxy_j.corr2])
                            append!(corr1_reverse_values, [galaxy_j.corr1])
                            append!(corr2_reverse_values, [galaxy_i.corr2])
                        end
                    end
                end

                ψ_bin = corr_metric(corr1_values, corr2_values, corr1_reverse_values, corr2_reverse_values)
                ψ_array[i,:] = [i, min_distance, max_distance, mean_distance, ψ_bin]
            end
        end
        
        if verbose
            println("Assigned data points to θ bins")
            println(ψ_array)
        end
        
        ψ_θ = zeros(2, number_bins - empty_bins) 
        for i in 1:(number_bins - empty_bins)
            ψ_θ[1,i] = ψ_array[i, 4]
            ψ_θ[2,i] = ψ_array[i, 5]
        end
        ψ_θ = ψ_θ[:, sortperm(ψ_θ[1,:])]
        
        if verbose
            plt = lineplot(log10.(ψ_θ[1,:]), log10.(abs.(ψ_θ[2,:])), title="Correlation Function", name="Correlation Function", xlabel="log10(θ)", ylabel="log10(ξ(θ))")
            println(plt)
        end
       
        return ψ_θ
    end
    
    function clustercorr(ra,
            dec, 
            corr1, 
            corr2, 
            θ_min, 
            number_bins, 
            θ_max; 
            cluster_factor=0.25, 
            spacing=log, 
            sky_metric=Vincenty_Formula, 
            kmeans_metric=Vincenty, 
            corr_metric=corr_metric, 
            splitter=split_galaxy_cells!,
            max_depth=3,
            bin_slop=nothing,
            verbose=false)
        @assert length(ra) == length(dec) == length(corr1) == length(corr2) "ra, dec, corr1, and corr2 must be the same length"
        
        if verbose
            scatterplot_galaxies = scatterplot(ra, dec, title="Object Positions", xlabel="RA", ylabel="DEC")
            densityplot_galaxies = densityplot(ra, dec, title="Object Density", xlabel="RA", ylabel="DEC")
            println("K means clustering")
        end
        
        sky_metric = sky_metric
        galaxies = [Galaxy(ra[i], dec[i], corr1[i], corr2[i]) for i in 1:length(ra)]
        clusters = round(Int, length(galaxies) * cluster_factor)
        
        if verbose
            println("Number of clusters: ", clusters)
            println("Clustering...")
        end
        
        circles = kmeans_clustering(galaxies, clusters, sky_metric=sky_metric, kmeans_metric=kmeans_metric, verbose=verbose)
        ra_circles = [circle.center[1] for circle in circles]
        dec_circles = [circle.center[2] for circle in circles]
        n = length(ra_circles)
        
        if verbose
            println("Clustering complete")
            println("Number of circles: ", n)
            scatterplot_clusters = scatterplot(ra_circles, dec_circles, title="Cluster Positions", xlabel="RA", ylabel="DEC")
            densityplot_clusters = densityplot(ra_circles, dec_circles, title="Cluster Density", xlabel="RA", ylabel="DEC")
            println("Computing Distance Matrix")
        end
        
        distance_matrix = build_distance_matrix(ra_circles, dec_circles, metric=sky_metric)
        
        if verbose
            println("Distance Matrix complete")
        end

        indices = [(i, j) for i in 1:n, j in 1:n if j < i]
        distance_vector = [distance_matrix[i, j] for (i, j) in indices]
        
        θ_bins = range(θ_min, stop=θ_max, length=number_bins)
        
        if spacing == log
            θ_bins = 10 .^ range(log10(θ_min), log10(θ_max), length=number_bins)
        end

        θ_bin_assignments = zeros(length(distance_vector))
        for i in 1:length(distance_vector)
            for j in 1:length(θ_bins)
                if distance_vector[i] < θ_bins[j] && distance_vector[i] > θ_min
                    θ_bin_assignments[i] = j
                    break
                end
            end
        end

        lock = ReentrantLock()
        df = DataFrame(bin_number=Int[], 
                       min_distance=Float64[], 
                       max_distance=Float64[], 
                       count=Int[], 
                       mean_distance=Float64[], 
                       corr1=Vector{Any}[], 
                       corr2=Vector{Any}[], 
                       corr1_reverse=Vector{Any}[], 
                       corr2_reverse=Vector{Any}[])
        
        if verbose
            println("Assigning data points to θ bins")
        end

        Threads.@threads for i in 1:number_bins
            bin = findall(θ_bin_assignments .== i)
            if !isempty(bin)
                min_distance = minimum(distance_vector[bin])
                max_distance = maximum(distance_vector[bin])
                mean_distance = mean(distance_vector[bin])
                bin_indices = [indices[k] for k in bin]

                corr1_values = []
                corr2_values = []

                corr1_reverse_values = []
                corr2_reverse_values = []
                
                for (i, j) in bin_indices
                    for galaxy_i in circles[i].galaxies
                        for galaxy_j in circles[j].galaxies
                            append!(corr1_values, [galaxies[galaxy_i].corr1])
                            append!(corr2_values, [galaxies[galaxy_j].corr2])
                            append!(corr1_reverse_values, [galaxies[galaxy_j].corr1])
                            append!(corr2_reverse_values, [galaxies[galaxy_i].corr2])
                        end
                    end
                end
                count = length(bin_indices)

                Threads.lock(lock) do
                    push!(df, (bin_number=i, 
                               min_distance=min_distance, 
                               max_distance=max_distance, 
                               count=count, 
                               mean_distance=mean_distance, 
                               corr1=corr1_values, 
                               corr2=corr2_values, 
                               corr1_reverse=corr1_reverse_values, 
                               corr2_reverse=corr2_reverse_values))
                end
            end
        end
        
        if verbose
            println("Assigned data points to θ bins")
            df = df[sortperm(df.mean_distance), :]
            println(df)
        end
        
        ψ_θ = zeros(2, number_bins) 
        @threads for i in 1:nrow(df)
            ψ_θ[1,i] = df[i, :mean_distance]
            c1 = df[i, :corr1]
            c2 = df[i, :corr2]
            c3 = df[i, :corr1_reverse]
            c4 = df[i, :corr2_reverse]
            ψ_θ[2,i] = corr_metric(c1, c2, c3, c4)
            ψ_θ = ψ_θ[:, sortperm(ψ_θ[1,:])]
        end
        return ψ_θ
    end

    function naivecorr(ra, 
            dec, 
            corr1,
            corr2,
            θ_min, 
            number_bins, 
            θ_max; 
            cluster_factor=0.25, 
            spacing=log, 
            sky_metric=Vincenty_Formula, 
            kmeans_metric=Vincenty,
            corr_metric=corr_metric, 
            splitter=split_galaxy_cells!,
            max_depth=3,
            bin_slop=nothing,
            verbose=false) 
        @assert length(ra) == length(dec) == length(corr1) == length(corr2) "ra, dec, corr1, and corr2 must be the same length"

        if verbose
            scatterplot_galaxies = scatterplot(ra, dec, title="Object Positions", xlabel="RA", ylabel="DEC")
            densityplot_galaxies = densityplot(ra, dec, title="Object Density", xlabel="RA", ylabel="DEC")
            println(scatterplot_galaxies)
            println(densityplot_galaxies)
            println("Naive Correlation")
            println("Computing Distance Matrix")
        end
        distance_matrix = build_distance_matrix(ra, dec, metric=sky_metric)

        n = length(ra)
        indices = [(i, j) for i in 1:n, j in 1:n if j < i]  
        distance_vector = [distance_matrix[i, j] for (i, j) in indices]
        
        θ_bins = range(θ_min, stop=θ_max, length=number_bins)
        
        if spacing == log
            θ_bins = 10 .^ range(log10(θ_min), log10(θ_max), length=number_bins)
        end
        
        if verbose
            println("θ min: ", θ_min, " θ max: ", θ_max)
        end

        θ_bin_assignments = zeros(length(distance_vector))
        for i in 1:length(distance_vector)
            for j in 1:length(θ_bins)
                if distance_vector[i] < θ_bins[j] && distance_vector[i] > θ_min
                    θ_bin_assignments[i] = j
                    break
                end
            end
        end

        lock = ReentrantLock()
        df = DataFrame(bin_number=Int[], 
                       min_distance=Float64[], 
                       max_distance=Float64[], 
                       count=Int[], 
                       mean_distance=Float64[], 
                       corr1=Vector{Any}[],
                       corr2=Vector{Any}[],
                       corr1_reverse=Vector{Any}[],
                       corr2_reverse=Vector{Any}[])
        
        if verbose
            println("Assigning data points to θ bins")
        end

        Threads.@threads for i in 1:number_bins
            bin = findall(θ_bin_assignments .== i)
            if !isempty(bin)
                min_distance = minimum(distance_vector[bin])
                max_distance = maximum(distance_vector[bin])
                mean_distance = mean(distance_vector[bin])
                bin_indices = [indices[k] for k in bin]
                corr1_values, corr2_values = [], []
                corr1_reverse_values, corr2_reverse_values = [], []

                for (i, j) in bin_indices
                    append!(corr1_values, corr1[i])
                    append!(corr2_values, corr2[j])
                    append!(corr1_reverse_values, corr1[j])
                    append!(corr2_reverse_values, corr2[i])
                end
                
                count = length(bin_indices)

                Threads.lock(lock) do
                    push!(df, (bin_number=i, 
                               min_distance=min_distance, 
                               max_distance=max_distance, 
                               count=count, 
                               mean_distance=mean_distance, 
                               corr1=corr1_values, 
                               corr2=corr2_values, 
                               corr1_reverse=corr1_reverse_values, 
                               corr2_reverse=corr2_reverse_values))
                end
            end
        end

        if verbose
            println("Assigned data points to θ bins")
            df = df[sortperm(df.mean_distance), :]
            println(df)
        end
        
        ψ_θ = zeros(2, number_bins) 
        @threads for i in 1:nrow(df)
            ψ_θ[1,i] = df[i, :mean_distance]
            c1 = df[i, :corr1]
            c2 = df[i, :corr2]
            c3 = df[i, :corr1_reverse]
            c4 = df[i, :corr2_reverse]
            ψ_θ[2,i] = corr_metric(c1, c2, c3, c4)
        end
        ψ_θ = ψ_θ[:, sortperm(ψ_θ[1,:])]

        if verbose
            plt = lineplot(log10.(ψ_θ[1,:]), log10.(abs.(ψ_θ[2,:])), title="Correlation Function", name="Correlation Function", xlabel="log10(θ)", ylabel="log10(ξ(θ))")
            println(plt)
        end

        return ψ_θ
    end
    
    #c1 is galaxy 1 quantity 1, c2 is galaxy 2 quantity 2, c3 is galaxy 2 quantity 1, c4 is galaxy 1 quantity 2
    
    corr_metric_default_scalar_scalar(c1,c2,c3,c4) = (sum(c1 .* c2) + sum(c3 .* c4)) / (length(c1) + length(c3))
    function corr_metric_default_vector_vector(c1,c2,c3,c4)
        k1 = sum([dot(c1[i], c2[j]) for i in 1:length(c1), j in 1:length(c2)])
        k2 = sum([dot(c3[i], c4[j]) for i in 1:length(c3), j in 1:length(c4)])
        denominator = length(c1) * length(c2) + length(c3) * length(c4)
        return (k1 + k2) / denominator
    end

    function rotate_shear(shear::shear)
        shear = shear.tan_cross
        ϕ = π / 4
        shear_tan_cross_galaxy = @. -exp(-2im * ϕ) * (shear[1] + (shear[2] * 1im))
        gtan_galaxy, gcross_galaxy = @. real(shear_tan_cross_galaxy), imag(shear_tan_cross_galaxy)
        return shear([gtan_galaxy, gcross_galaxy])
    end


    function corr_metric_default_shear_shear(c1,c2,c3,c4) 
        c1_rotated = [rotate_shear(c) for c in c1]
        c2_rotated = [rotate_shear(c) for c in c2]
        c3_rotated = [rotate_shear(c) for c in c3]
        c4_rotated = [rotate_shear(c) for c in c4]

        k1 = sum([dot(c1_rotated[i].tan_cross, c2_rotated[j].tan_cross) for i in 1:length(c1), j in 1:length(c2)])
        k2 = sum([dot(c3_rotated[i].tan_cross, c4_rotated[j].tan_cross) for i in 1:length(c3), j in 1:length(c4)])

        numerator = k1 + k2
        denominator = length(c1) * length(c2) + length(c3) * length(c4)
        return numerator / denominator
    end
    
    function corr_metric_shear_minus(c1,c2,c3,c4)
        c1_rotated = [rotate_shear(c) for c in c1]
        c2_rotated = [rotate_shear(c) for c in c2]
        c3_rotated = [rotate_shear(c) for c in c3]
        c4_rotated = [rotate_shear(c) for c in c4]

        k1 = sum(c1_rotated[i].tan_cross[1]*c2_rotated[j].tan_cross[1] - c1_rotated[i].tan_cross[2]*c2_rotated[j].tan_cross[2] for i in 1:length(c1), j in 1:length(c2))
        k2 = sum(c3_rotated[i].tan_cross[1]*c4_rotated[j].tan_cross[1] - c3_rotated[i].tan_cross[2]*c4_rotated[j].tan_cross[2] for i in 1:length(c3), j in 1:length(c4))
        return (k1 + k2) / (length(c1) + length(c3))
    end

    function ξ_plus(c1, c2, c3, c4)
        return corr_metric_default_vector_vector(c1, c2, c3, c4)
    end

    function ξ_minus(c1, c2, c3, c4)
        ϕ = π / 4
        shear_tan_cross_galaxy_one = @. -exp(-2im * ϕ) * (c1 + (c2 * 1im))
        gtan_galaxy_one, gcross_galaxy_one = @. real(shear_tan_cross_galaxy_one), imag(shear_tan_cross_galaxy_one)
        shear_tan_cross_galaxy_two = @. -exp(-2im * ϕ) * (c3 + (c4 * 1im))
        gtan_galaxy_two, gcross_galaxy_two = @. real(shear_tan_cross_galaxy_two), imag(shear_tan_cross_galaxy_two)
        numerator = 0
        for i in 1:length(c1)
            numerator += gtan_galaxy_one[i] * gtan_galaxy_two[i] - gcross_galaxy_one[i] * gcross_galaxy_two[i]
        end
        denominator = length(c1)
        return numerator / denominator
    end
    corr_metric_default_position_position(c1,c2,c3,c4) = length(c1)

    function corr(ra::Vector{Float64},
            dec::Vector{Float64}, 
            x::Vector{Vector{Float64}}, 
            y::Vector{Float64}, 
            θ_min::Float64, 
            number_bins::Int64, 
            θ_max::Float64; 
            cluster_factor=0.25,
            spacing=log, 
            sky_metric=Vincenty_Formula(),
            kmeans_metric=Vincenty,
            corr_metric=corr_metric_default,
            correlator=treecorr_stack,
            max_depth=100,
            bin_slop=nothing,
            verbose=false)
        return correlator(ra, 
                          dec, 
                          x, 
                          y, 
                          θ_min, 
                          number_bins, 
                          θ_max, 
                          cluster_factor=cluster_factor, 
                          spacing=spacing, 
                          sky_metric=sky_metric, 
                          kmeans_metric=kmeans_metric, 
                          corr_metric=corr_metric, 
                          max_depth=max_depth,
                          bin_slop=bin_slop,
                          verbose=verbose)
    end
    
    function corr(ra::Vector{Float64}, 
            dec::Vector{Float64}, 
            x::Vector{Float64}, 
            y::Vector{Vector{Float64}}, 
            θ_min::Float64, 
            number_bins::Int64, 
            θ_max::Float64; 
            cluster_factor=0.25,
            spacing=log, 
            sky_metric=Vincenty_Formula(),
            kmeans_metric=Vincenty,
            corr_metric=corr_metric_default,
            correlator=treecorr_stack,
            max_depth=100,
            bin_slop=nothing,
            verbose=false)
        return correlator(ra, 
                          dec, 
                          x, 
                          y, 
                          θ_min, 
                          number_bins, 
                          θ_max, 
                          cluster_factor=cluster_factor, 
                          spacing=spacing, 
                          sky_metric=sky_metric, 
                          kmeans_metric=kmeans_metric, 
                          corr_metric=corr_metric, 
                          max_depth=max_depth,
                          bin_slop=bin_slop,
                          verbose=verbose)
    end

    function corr(ra::Vector{Float64}, 
            dec::Vector{Float64}, 
            x::Vector{Vector{Complex{Float64}}}, 
            y::Vector{Float64}, 
            θ_min::Float64, 
            number_bins::Int64, 
            θ_max::Float64; 
            cluster_factor=0.25,
            spacing=log, 
            sky_metric=Vincenty_Formula(),
            kmeans_metric=Vincenty, 
            corr_metric=corr_metric_default,
            correlator=treecorr_stack,
            max_depth=100,
            bin_slop=nothing,
            verbose=false)
        return correlator(ra, 
                          dec, 
                          x, 
                          y, 
                          θ_min, 
                          number_bins, 
                          θ_max, 
                          cluster_factor=cluster_factor, 
                          spacing=spacing, 
                          sky_metric=sky_metric,
                          kmeans_metric=kmeans_metric,
                          corr_metric=corr_metric,
                          max_depth=max_depth,
                          bin_slop=bin_slop,
                          verbose=verbose)
    end
    
    function corr(ra::Vector{Float64}, 
            dec::Vector{Float64}, 
            x::Vector{Float64}, 
            y::Vector{Vector{Float64}}, 
            θ_min::Float64, 
            number_bins::Int64, 
            θ_max::Float64; 
            cluster_factor=0.25,
            spacing=log, 
            sky_metric=Vincenty_Formula(),
            kmeans_metric=Vincenty,
            corr_metric=corr_metric_default,
            correlator=treecorr_stack,
            max_depth=100,
            bin_slop=nothing,
            verbose=false)
        return correlator(ra, 
                          dec, 
                          x, 
                          y, 
                          θ_min, 
                          number_bins, 
                          θ_max, 
                          cluster_factor=cluster_factor, 
                          spacing=spacing, 
                          sky_metric=sky_metric,
                          kmeans_metric=kmeans_metric,
                          corr_metric=corr_metric, 
                          max_depth=max_depth,
                          bin_slop=bin_slop,
                          verbose=verbose)
    end
    
    function corr(ra::Vector{Float64}, 
            dec::Vector{Float64}, 
            x::Vector{Float64}, 
            y::Vector{Float64}, 
            θ_min::Float64, 
            number_bins::Int64, 
            θ_max::Float64; 
            cluster_factor=0.25,
            spacing=log, 
            sky_metric=Vincenty_Formula(),
            kmeans_metric=Vincenty,
            corr_metric=corr_metric_default_scalar_scalar,
            correlator=treecorr_stack,
            max_depth=100,
            bin_slop=nothing,
            verbose=false)
        return correlator(ra, 
                          dec, 
                          x, 
                          y, 
                          θ_min, 
                          number_bins, 
                          θ_max, 
                          cluster_factor=cluster_factor, 
                          spacing=spacing, 
                          sky_metric=sky_metric,
                          kmeans_metric=kmeans_metric,
                          corr_metric=corr_metric, 
                          max_depth=max_depth,
                          bin_slop=bin_slop,
                          verbose=verbose)
    end
    
    function corr(ra::Vector{Float64}, 
            dec::Vector{Float64}, 
            x::Vector{Position_RA_DEC},
            y::Vector{Position_RA_DEC},
            θ_min::Float64, 
            number_bins::Int64, 
            θ_max::Float64; 
            cluster_factor=0.25,
            spacing=log, 
            sky_metric=Vincenty_Formula,
            kmeans_metric=Vincenty,
            DD=DD,
            DR=DR,
            RR=RR,
            estimator=landy_szalay_estimator,
            correlator=treecorr_stack,
            splitter=split_galaxy_cells!,
            max_depth=100,
            bin_slop=nothing,
            verbose=false)
        println("Position Position Correlation")
        DD_cat = Galaxy_Catalog([pos.ra for pos in x if pos.value == "DATA"], 
                                [pos.dec for pos in x if pos.value == "DATA"], 
                                [pos.value for pos in x if pos.value == "DATA"],
                                [pos.value for pos in x if pos.value == "DATA"])
        DR_cat = Galaxy_Catalog([pos.ra for pos in x],
                                [pos.dec for pos in x],
                                [pos.value for pos in x],
                                [pos.value for pos in x])
        RR_cat = Galaxy_Catalog([pos.ra for pos in x if pos.value == "RANDOM"], 
                                [pos.dec for pos in x if pos.value == "RANDOM"], 
                                [pos.value for pos in x if pos.value == "RANDOM"],
                                [pos.value for pos in x if pos.value == "RANDOM"])

        θ_common = 10 .^(range(log10(θ_min), log10(θ_max), length=number_bins))
        
        if verbose
            println("Computing DD")
        end
        
        DD_θ = correlator(DD_cat.ra, 
                          DD_cat.dec, 
                          DD_cat.corr1,
                          DD_cat.corr2,
                          θ_min, 
                          number_bins, 
                          θ_max, 
                          cluster_factor=cluster_factor, 
                          spacing=spacing, 
                          sky_metric=sky_metric,
                          kmeans_metric=kmeans_metric,
                          corr_metric=DD, 
                          splitter=splitter,
                          max_depth=max_depth,
                          bin_slop=bin_slop,
                          verbose=verbose)
        
        if verbose
            println("DD complete")
            println("Computing DR")
        end
        
        DR_θ = correlator(DR_cat.ra,
                          DR_cat.dec,
                          DR_cat.corr1,
                          DR_cat.corr2,
                          θ_min, 
                          number_bins, 
                          θ_max, 
                          cluster_factor=cluster_factor, 
                          spacing=spacing, 
                          sky_metric=sky_metric, 
                          kmeans_metric=kmeans_metric,
                          corr_metric=DR, 
                          splitter=splitter,
                          max_depth=max_depth,
                          bin_slop=bin_slop,
                          verbose=verbose)
        
        if verbose
            println("DR complete")
            println("Computing RR")
        end
        
        RR_θ = correlator(RR_cat.ra,
                          RR_cat.dec,
                          RR_cat.corr1,
                          RR_cat.corr2,
                          θ_min, 
                          number_bins, 
                          θ_max, 
                          cluster_factor=cluster_factor, 
                          spacing=spacing, 
                          sky_metric=sky_metric,
                          kmeans_metric=kmeans_metric,
                          corr_metric=RR, 
                          splitter=splitter,
                          max_depth=max_depth,
                          bin_slop=bin_slop,
                          verbose=verbose)
        
        if verbose
            println("RR complete")
        end

        DD_interp = interpolate_to_common_bins_spline(DD_θ, θ_common)
        DR_interp = interpolate_to_common_bins_spline(DR_θ, θ_common)
        RR_interp = interpolate_to_common_bins_spline(RR_θ, θ_common)
        if verbose
            println("Interpolated to common bins")
            plt = lineplot(log10.(θ_common), log10.(abs.(estimator(DD_interp, DR_interp, RR_interp))), title="Correlation Function", name="Correlation Function", xlabel="log10(θ)", ylabel="log10(ξ(θ))")
            lineplot!(plt, log10.(θ_common), log10.(DD_interp), color=:red, name="DD")
            lineplot!(plt, log10.(θ_common), log10.(DR_interp), color=:yellow, name="DR")
            lineplot!(plt, log10.(θ_common), log10.(RR_interp), color=:cyan, name="RR")
            println(plt)
        end
        return estimator(DD_interp, DR_interp, RR_interp)
    end
    
    function corr(ra::Vector{Float64}, 
            dec::Vector{Float64}, 
            x::Vector{Vector{Float64}}, 
            y::Vector{Vector{Float64}}, 
            θ_min::Float64, 
            number_bins::Int64, 
            θ_max::Float64; 
            cluster_factor=0.25,
            spacing=log, 
            sky_metric=Vincenty_Formula,
            kmeans_metric=Vincenty,
            corr_metric=corr_metric_default_vector_vector,
            correlator=treecorr_stack,
            max_depth=100,
            bin_slop=nothing,
            verbose=false)
        return correlator(ra, 
                          dec, 
                          x, 
                          y, 
                          θ_min, 
                          number_bins, 
                          θ_max, 
                          cluster_factor=cluster_factor, 
                          spacing=spacing, 
                          sky_metric=sky_metric,
                          kmeans_metric=kmeans_metric,
                          corr_metric=corr_metric, 
                          max_depth=max_depth,
                          bin_slop=bin_slop,
                          verbose=verbose)
    end
    
    function corr(ra::Vector{Float64}, 
            dec::Vector{Float64}, 
            x::Vector{shear}, 
            y::Vector{shear},
            θ_min::Float64, 
            number_bins::Int64, 
            θ_max::Float64; 
            cluster_factor=0.25,
            spacing=log, 
            sky_metric=Vincenty_Formula,
            kmeans_metric=Vincenty,
            corr_metric=corr_metric_default_shear_shear,
            correlator=treecorr_stack,
            max_depth=100,
            bin_slop=nothing,
            verbose=false)
        return correlator(ra, 
                          dec, 
                          x, 
                          y, 
                          θ_min, 
                          number_bins, 
                          θ_max, 
                          cluster_factor=cluster_factor, 
                          spacing=spacing, 
                          sky_metric=sky_metric,
                          kmeans_metric=kmeans_metric,
                          corr_metric=corr_metric, 
                          max_depth=max_depth,
                          bin_slop=bin_slop,
                          verbose=verbose)
    end
    #=
    Rest of corr functions here, multiple dispatch!
    =#
    #=
    #example
    #gal_cal = galaxy_catalog([1,2,3,4,5], [1,2,3,4,5], [1,2,3,4,5], [1,2,3,4,5])
    #cor(θ) = corr(gal_cal.ra, gal_cal.dec, gal_cal.corr1, gal_cal.corr2)
    =#

end
