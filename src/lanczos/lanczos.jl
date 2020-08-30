using Base.Cartesian
using StaticArrays

export Lanczos, Lanczos4OpenCV

abstract type AbstractLanczos <: InterpolationType end

"""
    Lanczos{N}(a=4)

Lanczos resampling via a kernel with scale parameter `a` and support over `N` neighbors.

This form of interpolation is merely the discrete convolution of the samples with a Lanczos kernel of size `a`. The size is directly related to how "far" the interpolation will reach for information, and has `O(N^2)` impact on runtime. An alternative implementation matching `lanczos4` from OpenCV is available as Lanczos4OpenCV.
"""
struct Lanczos{N} <: AbstractLanczos
    a::Int
    
    function Lanczos{N}(a) where N
        N < a && @warn "Using a smaller support than scale for Lanczos window. Proceed with caution."
        new{N}(a)
    end
end

Lanczos(a=4) = Lanczos{a}(a)

"""
    LanczosInterpolation
"""
struct LanczosInterpolation{T,N,IT <: DimSpec{AbstractLanczos},A <: AbstractArray{T,N},P <: Tuple{Vararg{AbstractArray,N}}} <: AbstractInterpolation{T,N,IT}
    coefs::A
    parentaxes::P
    it::IT
end

@generated degree(::Lanczos{N}) where {N} = :($N)

getknots(itp::LanczosInterpolation) = axes(itp)
coefficients(itp::LanczosInterpolation) = itp.coefs
itpflag(itp::LanczosInterpolation) = itp.it

size(itp::LanczosInterpolation) = map(length, itp.parentaxes)
axes(itp::LanczosInterpolation) = itp.parentaxes
lbounds(itp::LanczosInterpolation) = map(first, itp.parentaxes)
ubounds(itp::LanczosInterpolation) = map(last, itp.parentaxes)

function interpolate(A::AbstractArray{T}, it::AbstractLanczos) where T
    Apad = copy_with_padding(float(T), A, it)
    return LanczosInterpolation(Apad, axes(A), it)
end

@inline function (itp::LanczosInterpolation{T,N})(x::Vararg{<:Number,N}) where {T,N}
    @boundscheck (checkbounds(Bool, itp, x...) || Base.throw_boundserror(itp, x))
    wis = weightedindexes((value_weights,), itpinfo(itp)..., x)
    itp.coefs[wis...]
end

function weightedindex_parts(fs, it::AbstractLanczos, ax::AbstractUnitRange{<:Integer}, x)
    pos, δx = positions(it, ax, x)
    (position = pos, coefs = fmap(fs, it, δx))
end

function positions(it::AbstractLanczos, ax, x)
    xf = floorbounds(x, ax)
    δx = x - xf
    fast_trunc(Int, xf) - degree(it) + 1, δx
end

function value_weights(it::Lanczos, δx::S) where S
    N = degree(it)
    # short-circuit if integral
    isinteger(δx) && return ntuple(i->convert(float(S), i == N - δx), Val(2N))

    # LUTs
    #it.a === N === 4 && return _lanczos4(δx)

    cs = ntuple(i -> lanczos(N - i + δx, it.a, N), Val(2N))
    sum_cs = sum(cs)
    @info sum_cs
    normed_cs = ntuple(i -> cs[i] / sum_cs, Val(length(cs)))
    return normed_cs
end

function padded_axis(ax::AbstractUnitRange, it::AbstractLanczos)
    N = degree(it)
    return first(ax) - N + 1:last(ax) + N
end

# precise implementations for fast evaluation of common kernels

"""
    lanczos(x, a, n=a)

Implementation of the [Lanczos kernel](https://en.wikipedia.org/wiki/Lanczos_resampling)
"""
lanczos(x::T, a::Integer, n=a) where {T} = abs(x) < n ? T(sinc(x) * sinc(x / a)) : zero(T)

"""
    Lanczos4OpenCV()

Alternative implementation of Lanczos resampling using algorithm `lanczos4` function of OpenCV:
https://github.com/opencv/opencv/blob/de15636724967faf62c2d1bce26f4335e4b359e5/modules/imgproc/src/resize.cpp#L917-L946
"""
struct Lanczos4OpenCV <: AbstractLanczos
end

degree(::Lanczos4OpenCV) = 4

value_weights(::Lanczos4OpenCV, δx::S) where S = ifelse(isinteger(δx),ntuple(i->convert(float(S), i == 4 - δx), Val(8)) ,_lanczos4_opencv(δx))

const s45 = 0.70710678118654752440084436210485
const l4_2d_cs = SA[1 0; -s45 -s45; 0 1; s45 -s45; -1 0; s45 s45; 0 -1; -s45 s45]


function _lanczos4_opencv(δx)
    p_4 = π / 4
    y0 = -(δx + 3) * p_4
    s0, c0 = sincos(y0)
    cs = ntuple(8) do i
        y = (δx + 4 - i) * p_4
        (l4_2d_cs[i, 1] * s0 + l4_2d_cs[i, 2] * c0) / y^2
    end
    sum_cs = sum(cs)
    normed_cs = ntuple(i -> cs[i] / sum_cs, Val(8))
    return normed_cs
end
