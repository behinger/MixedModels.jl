"""
    FeMat{T,S}

Term with an explicit, constant matrix representation

# Fields
* `x`: matrix
* `wtx`: weighted matrix
* `piv`: pivot `Vector{Int}` for moving linearly dependent columns to the right
* `rank`: computational rank of `x`
* `cnames`: vector of column names

"""
mutable struct FeMat{T,S<:AbstractMatrix}
    x::S
    wtx::S
    piv::Vector{Int}
    rank::Int
    cnames::Vector{String}
end

"""
    FeMat(X::AbstractMatrix, cnms)
    
Convenience constructor for [`FeMat`](@ref) that computes the rank and pivot with unit weights.

See the vignette "[Rank deficiency in mixed-effects models](@ref)" for more information on the 
computation of the rank and pivot.
"""
function FeMat(X::AbstractMatrix, cnms)
    T = eltype(X)
    if size(X,2) > 0
        st = statsqr(X)
        pivot = st.p
        rank = findfirst(<=(0), diff(st.p))
        rank = isnothing(rank) ? length(pivot) : rank
        Xp = pivot == collect(1:size(X, 2)) ? X : X[:, pivot]
        # single-column rank deficiency is the result of a constant column vector
        # this generally happens when constructing a dummy response, so we don't
        # warn.
        if rank < length(pivot) && size(X,2) > 1
            @warn "Fixed-effects matrix is rank deficient"
        end
    else
        # although it doesn't take long for an empty matrix,
        # we can still skip the factorization step, which gets the rank
        # wrong anyway
        pivot = Int[]
        Xp = X
        rank = 0
    end
    FeMat{T,typeof(X)}(Xp, Xp, pivot, rank, cnms[pivot])
end

"""
    FeMat(X::SparseMatrixCSC, cnms)
    
Convenience constructor for a sparse [`FeMat`](@ref) assuming full rank, identity pivot and unit weights.

Note: automatic rank deficiency handling may be added to this method in the future, as discused in
the vignette "[Rank deficiency in mixed-effects models](@ref)" for general `FeMat`.
"""
function FeMat(X::SparseMatrixCSC, cnms)
    @debug "Full rank is assumed for sparse fixed-effect matrices."
    rank = size(X,2)
    FeMat{eltype(X),typeof(X)}(X, X, 1:rank, rank, cnms)
end

function reweight!(A::FeMat{T}, sqrtwts::Vector{T}) where {T}
    if !isempty(sqrtwts)
        if A.x === A.wtx
            A.wtx = similar(A.x)
        end
        mul!(A.wtx, Diagonal(sqrtwts), A.x)
    end
    A
end

Base.adjoint(A::FeMat) = Adjoint(A)

Base.eltype(A::FeMat{T}) where {T} = T

fullrankwtx(A::FeMat) = rank(A) == size(A, 2) ? A.wtx : A.wtx[:, 1:rank(A)]

Base.length(A::FeMat) = length(A.wtx)

LinearAlgebra.rank(A::FeMat) = A.rank

Base.size(A::FeMat) = size(A.wtx)

Base.size(A::Adjoint{T,<:FeMat{T}}) where {T} = reverse(size(A.parent))

Base.size(A::FeMat, i) = size(A.wtx, i)

Base.copyto!(A::FeMat{T}, src::AbstractVecOrMat{T}) where {T} = copyto!(A.x, src)

*(adjA::Adjoint{T,<:FeMat{T}}, B::FeMat{T}) where {T} =
    fullrankwtx(adjA.parent)' * fullrankwtx(B)

LinearAlgebra.mul!(R::StridedVecOrMat{T}, A::FeMat{T}, B::StridedVecOrMat{T}) where {T} =
    mul!(R, A.x, B)

LinearAlgebra.mul!(C, adjA::Adjoint{T,<:FeMat{T}}, B::FeMat{T}) where {T} =
    mul!(C, fullrankwtx(adjA.parent)', fullrankwtx(B))

"""
    isfullrank(A::FeMat)

Does `A` have full column rank?
"""
isfullrank(A::FeMat) = A.rank == length(A.piv)
