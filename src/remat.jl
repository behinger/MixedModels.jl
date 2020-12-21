abstract type AbstractReMat{T,S} <: AbstractMatrix{T} end

"""
    ReMat{T,S} <: AbstractMatrix{T}

A section of a model matrix generated by a random-effects term.

# Fields
- `trm`: the grouping factor as a `StatsModels.CategoricalTerm`
- `refs`: indices into the levels of the grouping factor as a `Vector{Int32}`
- `levels`: the levels of the grouping factor
- `z`: transpose of the model matrix generated by the left-hand side of the term
- `wtz`: a weighted copy of `z` (`z` and `wtz` are the same object for unweighted cases)
- `λ`: a `LowerTriangular` matrix of size `S×S`
- `inds`: a `Vector{Int}` of linear indices of the potential nonzeros in `λ`
- `adjA`: the adjoint of the matrix as a `SparseMatrixCSC{T}`
"""
mutable struct ReMat{T,S} <: AbstractReMat{T,S}
    trm
    refs::Vector{Int32}
    levels
    cnames::Vector{String}
    z::Matrix{T}
    wtz::Matrix{T}
    λ::LowerTriangular{T,Matrix{T}}
    inds::Vector{Int}
    adjA::SparseMatrixCSC{T,Int32}
    scratch::Matrix{T}
end

"""
    amalgamate(reterms::Vector{AbstractReMat})

Combine multiple AbstractReMat with the same grouping variable into a single object.
"""
amalgamate(reterms::Vector{AbstractReMat{T}}) where {T} = _amalgamate(reterms,T)

function _amalgamate(reterms::Vector, T::Type)
    factordict = Dict{Symbol, Vector{Int}}()
    for (i, rt) in enumerate(reterms)
        push!(get!(factordict, fname(rt), Int[]), i)
    end
    length(factordict) == length(reterms) && return reterms
    ReTermType = Base.typename(typeof(reterms[1])).wrapper # get the instantiation of AbstractReMat
    value = AbstractReMat{T}[]
    for (f, inds) in factordict
        if isone(length(inds))
            push!(value, reterms[only(inds)])
        else
            trms = reterms[inds]
            trm1 = first(trms)
            trm = trm1.trm
            refs = refarray(trm1)
            levs = trm1.levels
            cnames =  foldl(vcat, rr.cnames for rr in trms)
            z = foldl(vcat, rr.z for rr in trms)

            Snew = size(z, 1)
            btemp = Matrix{Bool}(I, Snew, Snew)
            offset = 0
            for m in indmat.(trms)
                sz = size(m, 1)
                inds = (offset + 1):(offset + sz)
                view(btemp, inds, inds) .= m
                offset += sz
            end
            inds = (1:abs2(Snew))[vec(btemp)]

            λ = LowerTriangular(Matrix{T}(I, Snew, Snew))
            scratch =  foldl(vcat, rr.scratch for rr in trms)

            push!(
                value,
                ReTermType{T,Snew}(trm, refs, levs, cnames, z, z, λ, inds, adjA(refs,z), scratch)
            )
        end
    end
    value
end

"""
    adjA(refs::AbstractVector, z::AbstractMatrix{T})

Returns the adjoint of an `AbstractReMat` as a `SparseMatrixCSC{T,Int32}`
"""
function adjA(refs::AbstractVector, z::AbstractMatrix)
    S, n = size(z)
    length(refs) == n || throw(DimensionMismatch)
    J = Int32.(1:n)
    II = refs
    if S > 1
        J = repeat(J, inner=S)
        II = Int32.(vec([(r - 1)*S + j for j in 1:S, r in refs]))
    end
    sparse(II, J, vec(z))
end

Base.size(A::AbstractReMat) = (length(A.refs), length(A.scratch))

SparseArrays.sparse(A::AbstractReMat) = adjoint(A.adjA)

Base.getindex(A::AbstractReMat, i::Integer, j::Integer) = getindex(A.adjA, j, i)

"""
    nranef(A::AbstractReMat)

Return the number of random effects represented by `A`.  Zero unless `A` is an `AbstractReMat`.
"""
nranef(A::AbstractReMat) = size(A.adjA, 1)

LinearAlgebra.cond(A::AbstractReMat) = cond(A.λ)

"""
    fname(A::AbstractReMat)

Return the name of the grouping factor as a `Symbol`
"""
fname(A::AbstractReMat) = fname(A.trm)
fname(A::CategoricalTerm) = A.sym
fname(A::InteractionTerm) = Symbol(join(fname.(A.terms), " & "))

getθ(A::AbstractReMat{T}) where {T} = getθ!(Vector{T}(undef, nθ(A)), A)

"""
    getθ!(v::AbstractVector{T}, A::AbstractReMat{T}) where {T}

Overwrite `v` with the elements of the blocks in the lower triangle of `A.Λ` (column-major ordering)
"""
function getθ!(v::AbstractVector{T}, A::AbstractReMat{T}) where {T}
    length(v) == length(A.inds) || throw(DimensionMismatch("length(v) ≠ length(A.inds)"))
    m = A.λ.data
    @inbounds for (j, ind) in enumerate(A.inds)
        v[j] = m[ind]
    end
    v
end

function DataAPI.levels(A::AbstractReMat)
    # These checks are for cases where unused levels are present.
    # Such cases may never occur b/c of the way an AbstractReMat is constructed.
    pool = A.levels
    present = falses(size(pool))
    @inbounds for i in A.refs
        present[i] = true
        all(present) && return pool
    end
    pool[present]
end

"""
    indmat(A::AbstractReMat)

Return a `Bool` indicator matrix of the potential non-zeros in `A.λ`
"""
function indmat end

indmat(rt::AbstractReMat{T,1}) where {T} = ones(Bool, 1, 1)
indmat(rt::AbstractReMat{T,S}) where {T,S} = reshape([i in rt.inds for i in 1:abs2(S)], S, S)

nlevs(A::AbstractReMat) = length(A.levels)

"""
    nθ(A::AbstractReMat)

Return the number of free parameters in the relative covariance matrix λ
"""
nθ(A::AbstractReMat) = length(A.inds)

"""
    lowerbd{T}(A::AbstractReMat{T})

Return the vector of lower bounds on the parameters, `θ` associated with `A`

These are the elements in the lower triangle of `A.λ` in column-major ordering.
Diagonals have a lower bound of `0`.  Off-diagonals have a lower-bound of `-Inf`.
"""
lowerbd(A::AbstractReMat{T}) where {T} =
    T[x ∈ diagind(A.λ.data) ? zero(T) : T(-Inf) for x in A.inds]

"""
    isnested(A::AbstractReMat, B::AbstractReMat)

Is the grouping factor for `A` nested in the grouping factor for `B`?

That is, does each value of `A` occur with just one value of B?
"""
function isnested(A::AbstractReMat, B::AbstractReMat)
    size(A, 1) == size(B, 1) || throw(DimensionMismatch("must have size(A,1) == size(B,1)"))
    bins = zeros(Int32, nlevs(A))
    @inbounds for (a, b) in zip(A.refs, B.refs)
        bba = bins[a]
        if iszero(bba)    # bins[a] not yet set?
            bins[a] = b   # set it
        elseif bba ≠ b    # set to another value?
            return false
        end
    end
    true
end

function lmulΛ!(adjA::Adjoint{T,<:AbstractReMat{T,1}}, B::Matrix{T}) where {T}
    lmul!(only(adjA.parent.λ.data), B)
end

function lmulΛ!(adjA::Adjoint{T,<:AbstractReMat{T,1}}, B::SparseMatrixCSC{T}) where {T}
    lmul!(only(adjA.parent.λ.data), nonzeros(B))
    B
end

function lmulΛ!(adjA::Adjoint{T,<:AbstractReMat{T,1}}, B::M) where{M<:AbstractMatrix{T}} where {T}
    lmul!(only(adjA.parent.λ.data), B)
end

function lmulΛ!(adjA::Adjoint{T,<:AbstractReMat{T,S}}, B::VecOrMat{T}) where {T,S}
    lmul!(adjoint(adjA.parent.λ), reshape(B, S, :))
    B
end

function lmulΛ!(adjA::Adjoint{T,<:AbstractReMat{T,S}}, B::BlockedSparse{T}) where {T,S}
    lmulΛ!(adjA, nonzeros(B.cscmat))
    B
end

function lmulΛ!(adjA::Adjoint{T,<:AbstractReMat{T,1}}, B::BlockedSparse{T,1,P}) where {T,P}
    lmul!(only(adjA.parent.λ.data), nonzeros(B.cscmat))
    B
end

function lmulΛ!(adjA::Adjoint{T,<:AbstractReMat{T,S}}, B::SparseMatrixCSC{T}) where {T,S}
    lmulΛ!(adjA, nonzeros(B))
    B
end

LinearAlgebra.Matrix(A::AbstractReMat) = Matrix(sparse(A))

function LinearAlgebra.mul!(C::Diagonal{T}, adjA::Adjoint{T,<:AbstractReMat{T,1}},
        B::AbstractReMat{T,1}) where {T}
    A = adjA.parent
    @assert A === B
    d = C.diag
    fill!(d, zero(T))
    @inbounds for (ri, Azi) in zip(A.refs, A.wtz)
        d[ri] += abs2(Azi)
    end
    C
end

function *(adjA::Adjoint{T,<:AbstractReMat{T,1}}, B::AbstractReMat{T,1}) where {T}
    A = adjA.parent
    A === B ? mul!(Diagonal(Vector{T}(undef, size(B, 2))), adjA, B) :
    sparse(Int32.(A.refs), Int32.(B.refs), vec(A.wtz .* B.wtz))
end

*(adjA::Adjoint{T,<:AbstractReMat{T}}, B::AbstractReMat{T}) where {T} = adjA.parent.adjA * sparse(B)
*(adjA::Adjoint{T,<:FeMat{T}}, B::AbstractReMat{T}) where {T} =
    mul!(Matrix{T}(undef, rank(adjA.parent), size(B, 2)), adjA, B)

function LinearAlgebra.mul!(C::Matrix{T}, adjA::Adjoint{T,<:FeMat{T}}, B::AbstractReMat{T,1},
        α::Number, β::Number) where {T}
    A = adjA.parent
    Awt = A.wtx
    n, p = size(Awt)
    r = A.rank
    m, q = size(B)
    size(C) == (r, q) && m == n || throw(DimensionMismatch())
    isone(β) || rmul!(C, β)
    zz = B.wtz
    @inbounds for (j, rrj) in enumerate(B.refs)
        αzj = α * zz[j]
        for i in 1:r
            C[i, rrj] += αzj * Awt[j, i]
        end
    end
    C
end

function LinearAlgebra.mul!(C::Matrix{T}, adjA::Adjoint{T,<:FeMat{T}}, B::AbstractReMat{T,S},
    α::Number, β::Number) where {T,S}
    A = adjA.parent
    Awt = A.wtx
    r = rank(A)
    rr = B.refs
    scr = B.scratch
    vscr = vec(scr)
    Bwt = B.wtz
    n = length(rr)
    q = length(scr)
    size(C) == (r, q) && size(Awt, 1) == n || throw(DimensionMismatch(""))
    isone(β) || rmul!(C, β)
    @inbounds for i in 1:r
        fill!(scr, 0)
        for k in 1:n
            aki = α * Awt[k,i]
            kk = Int(rr[k])
            for ii in 1:S
                scr[ii, kk] += aki * Bwt[ii, k]
            end
        end
        for j in 1:q
            C[i, j] += vscr[j]
        end
    end
    C
end

function LinearAlgebra.mul!(C::SparseMatrixCSC{T}, adjA::Adjoint{T,<:AbstractReMat{T,1}},
        B::AbstractReMat{T,1}) where {T}
    A = adjA.parent
    m, n = size(B)
    size(C, 1) == size(A, 2) && n == size(C, 2) && size(A, 1) == m || throw(DimensionMismatch)
    Ar = A.refs
    Br = B.refs
    Az = A.wtz
    Bz = B.wtz
    nz = nonzeros(C)
    rv = rowvals(C)
    fill!(nz, zero(T))
    for k in 1:m       # iterate over rows of A and B
        i = Ar[k]      # [i,j] are Cartesian indices in C - find and verify corresponding position K in rv and nz
        j = Br[k]
        coljlast = Int(C.colptr[j + 1] - 1)
        K = searchsortedfirst(rv, i, Int(C.colptr[j]), coljlast, Base.Order.Forward)
        if K ≤ coljlast && rv[K] == i
            nz[K] += Az[k] * Bz[k]
        else
            throw(ArgumentError("C does not have the nonzero pattern of A'B"))
        end
    end
    C
end

function LinearAlgebra.mul!(C::UniformBlockDiagonal{T}, adjA::Adjoint{T,<:AbstractReMat{T,S}}, B::AbstractReMat{T,S}) where {T,S}
    A = adjA.parent
    @assert A === B
    Cd = C.data
    size(Cd) == (S, S, nlevs(B)) || throw(DimensionMismatch(""))
    fill!(Cd, zero(T))
    Awtz = A.wtz
    for (j, r) in enumerate(A.refs)
        @inbounds for i in 1:S
            zij = Awtz[i,j]
            for k in 1:S
                Cd[k, i, r] += zij * Awtz[k,j]
            end
        end
    end
    C
end

function LinearAlgebra.mul!(C::Matrix{T}, adjA::Adjoint{T,<:AbstractReMat{T,S}},
        B::AbstractReMat{T,P}) where {T,S,P}
    A = adjA.parent
    m, n = size(A)
    p, q = size(B)
    m == p && size(C, 1) == n && size(C, 2) == q || throw(DimensionMismatch(""))
    fill!(C, zero(T))

    Ar = A.refs
    Br = B.refs
    if isone(S) && isone(P)
        for (ar, az, br, bz) in zip(Ar, vec(A.wtz), Br, vec(B.wtz))
            C[ar, br] += az * bz
        end
        return C
    end
    ab = S * P
    Az = A.wtz
    Bz = B.wtz
    for i in 1:m
        Ari = Ar[i]
        Bri = Br[i]
        ioffset = (Ari - 1) * S
        joffset = (Bri - 1) * P
        for jj in 1:P
            jjo = jj + joffset
            Bzijj = Bz[jj, i]
            for ii in 1:S
                C[ii + ioffset, jjo] += Az[ii, i] * Bzijj
            end
        end
    end
    C
end

function *(adjA::Adjoint{T,<:AbstractReMat{T,S}}, B::AbstractReMat{T,P}) where {T,S,P}
    A = adjA.parent
    if A === B
        return mul!(UniformBlockDiagonal(Array{T}(undef, S, S, nlevs(A))), adjA, A)
    end
    cscmat = A.adjA * adjoint(B.adjA)
    if nnz(cscmat) > *(0.25, size(cscmat)...)
        return Matrix(cscmat)
    end

    BlockedSparse{T,S,P}(cscmat, reshape(cscmat.nzval, S, :), cscmat.colptr[1:P:(cscmat.n + 1)])
end

function PCA(A::AbstractReMat{T,1}; corr::Bool=true) where {T}
    val = ones(T, 1, 1)
    # TODO: use DataAPI
    PCA(corr ? val : abs(only(A.λ)) * val, A.cnames; corr=corr)
end

# TODO: use DataAPI
PCA(A::AbstractReMat{T,S}; corr::Bool=true) where {T,S} = PCA(A.λ, A.cnames; corr=corr)

refarray(A::AbstractReMat) = A.refs

refpool(A::AbstractReMat) = A.levels

refvalue(A::AbstractReMat, i::Integer) = A.levels[i]

function reweight!(A::AbstractReMat, sqrtwts::Vector)
    if length(sqrtwts) > 0
        if A.z === A.wtz
            A.wtz = similar(A.z)
        end
        rmul!(copyto!(A.wtz, A.z), Diagonal(sqrtwts))
    end
    A
end

rmulΛ!(A::Matrix{T}, B::AbstractReMat{T,1}) where{T} = rmul!(A, only(B.λ.data))

function rmulΛ!(A::SparseMatrixCSC{T}, B::AbstractReMat{T,1}) where {T}
    rmul!(nonzeros(A), only(B.λ.data))
    A
end

function rmulΛ!(A::Matrix{T}, B::AbstractReMat{T,S}) where {T,S}
    m, n = size(A)
    q, r = divrem(n, S)
    iszero(r) || throw(DimensionMismatch("size(A, 2) is not a multiple of block size"))
    λ = B.λ
    for k = 1:q
        coloffset = (k - 1) * S
        rmul!(view(A, :, coloffset+1:coloffset+S), λ)
    end
    A
end

function rmulΛ!(A::BlockedSparse{T,S,P}, B::AbstractReMat{T,P}) where {T,S,P}
    cbpt = A.colblkptr
    csc = A.cscmat
    nzv = csc.nzval
    for j in 1:div(csc.n, P)
        rmul!(reshape(view(nzv, cbpt[j]:(cbpt[j + 1] - 1)), :, P), B.λ)
    end
    A
end

rowlengths(A::AbstractReMat{T,1}) where {T} = vec(abs.(A.λ.data))

function rowlengths(A::AbstractReMat)
    ld = A.λ.data
    [norm(view(ld, i, 1:i)) for i in 1:size(ld, 1)]
end

"""
    scaleinflate!(L::AbstractMatrix, Λ::AbstractReMat)

Overwrite L with `Λ'LΛ + I`
"""
function scaleinflate! end

function scaleinflate!(Ljj::Diagonal{T}, Λj::AbstractReMat{T,1}) where {T}
    Ljjd = Ljj.diag
    broadcast!((x, λsqr) -> x * λsqr + 1, Ljjd, Ljjd, abs2(only(Λj.λ.data)))
    Ljj
end

function scaleinflate!(Ljj::Matrix{T}, Λj::AbstractReMat{T,1}) where {T}
    lambsq = abs2(only(Λj.λ.data))
    @inbounds for i in diagind(Ljj)
        Ljj[i] *= lambsq
        Ljj[i] += one(T)
    end
    Ljj
end

function scaleinflate!(Ljj::UniformBlockDiagonal{T}, Λj::AbstractReMat{T,S}) where {T,S}
    λ = Λj.λ
    dind = diagind(S, S)
    Ldat = Ljj.data
    for k in axes(Ldat, 3)
        f = view(Ldat, :, :, k)
        lmul!(λ', rmul!(f, λ))
        for i in dind
            f[i] += one(T)  # inflate diagonal
        end
    end
    Ljj
end

function scaleinflate!(Ljj::Matrix{T}, Λj::AbstractReMat{T,S}) where{T,S}
    n = LinearAlgebra.checksquare(Ljj)
    q, r = divrem(n, S)
    iszero(r) || throw(DimensionMismatch("size(Ljj, 1) is not a multiple of S"))
    λ = Λj.λ
    offset = 0
    @inbounds for k in 1:q
        inds = (offset + 1):(offset + S)
        tmp = view(Ljj, inds, inds)
        lmul!(adjoint(λ), rmul!(tmp, λ))
        offset += S
    end
    for k in diagind(Ljj)
        Ljj[k] += 1
    end
    Ljj
end

function setθ!(A::AbstractReMat{T}, v::AbstractVector{T}) where {T}
    A.λ.data[A.inds] = v
    A
end

function σs(A::AbstractReMat{T,1}, sc::T) where {T}
    NamedTuple{(Symbol(only(A.cnames)),)}(sc*abs(only(A.λ.data)),)
end

function σs(A::AbstractReMat{T}, sc::T) where {T}
    λ = A.λ.data
    NamedTuple{(Symbol.(A.cnames)...,)}(ntuple(i -> sc*norm(view(λ,i,1:i)), size(λ, 1)))
end

function σρs(A::AbstractReMat{T,1}, sc::T) where {T}
    NamedTuple{(:σ,:ρ)}(
        (NamedTuple{(Symbol(only(A.cnames)),)}((sc*abs(only(A.λ.data)),)), ())
    )
end

function ρ(i, λ::AbstractMatrix{T}, im::Matrix{Bool}, indpairs, σs, sc::T)::T where {T}
    row, col = indpairs[i]
    if iszero(dot(view(im, row, :), view(im, col, :)))
        -zero(T)
    else
        dot(view(λ, row, :), view(λ, col, :)) * abs2(sc) / (σs[row] * σs[col])
    end
end

function σρs(A::AbstractReMat{T}, sc::T) where {T}
    λ = A.λ.data
    k = size(λ, 1)
    im = indmat(A)
    indpairs = checkindprsk(k)
    σs = NamedTuple{(Symbol.(A.cnames)...,)}(ntuple(i -> sc*norm(view(λ,i,1:i)), k))
    NamedTuple{(:σ,:ρ)}((σs, ntuple(i -> ρ(i,λ,im,indpairs,σs,sc), (k * (k - 1)) >> 1)))
end

"""
    corrmat(A::AbstractReMat)

Return the estimated correlation matrix for `A`.  The diagonal elements are 1
and the off-diagonal elements are the correlations between those random effect
terms

# Example

Note that trailing digits may vary slightly depending on the local platform.

```julia-repl
julia> using MixedModels

julia> mod = fit(MixedModel,
                 @formula(rt_trunc ~ 1 + spkr + prec + load + (1 + spkr + prec | subj)),
                 MixedModels.dataset(:kb07));

julia> VarCorr(mod)
Variance components:
             Column      Variance  Std.Dev.  Corr.
subj     (Intercept)     136591.782 369.583
         spkr: old        22922.871 151.403 +0.21
         prec: maintain   32348.269 179.856 -0.98 -0.03
Residual                 642324.531 801.452

julia> MixedModels.corrmat(mod.reterms[1])
3×3 LinearAlgebra.Symmetric{Float64,Array{Float64,2}}:
  1.0        0.214816   -0.982948
  0.214816   1.0        -0.0315607
 -0.982948  -0.0315607   1.0
```
"""
function corrmat(A::AbstractReMat{T}) where {T}
    λ = A.λ
    λnorm = rownormalize!(copy!(zeros(T, size(λ)), λ))
    Symmetric(λnorm * λnorm', :L)
end

vsize(A::AbstractReMat{T,S}) where {T,S} = S

function zerocorr!(A::AbstractReMat{T}) where {T}
    λ = A.λ
    # zero out all entries not on the diagonal
    λ[setdiff(A.inds, diagind(λ))] .= 0
    A.inds = intersect(A.inds, diagind(λ))
    A
end
