include("../src/corr.jl")
using .astrocorr

using PyCall
using Statistics
using UnicodePlots
using Base.Threads
using Statistics

println(nthreads())

fits = pyimport("astropy.io.fits")
f = fits.open("Aardvark.fit")
print(f[2].data)

ra = f[2].data["RA"]
dec = f[2].data["DEC"]
ra = convert(Vector{Float64}, ra)
dec = convert(Vector{Float64}, dec)
println(mean(ra))
println(mean(dec))
println(scatterplot(ra, dec, title="RA vs DEC Scatterplot", xlabel="RA", ylabel="DEC"))

positions = [Position_RA_DEC(ra, dec, "DATA") for (ra, dec) in zip(ra, dec)]

corr(ra, dec, positions, positions, 1.0, 100, 400.0; verbose=true)
