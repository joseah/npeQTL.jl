"""
Modified bootstrapping code from https://github.com/palday/MixedModelsPermutations.jl 
by Phillip Alday
"""


"""
    nonparametricbootstrap([rng::AbstractRNG,] nsamp::Integer, m::LinearMixedModel;
                           use_threads=false, blup_method=ranef, β=coef(morig))

Perform `nsamp` nonparametric bootstrap replication fits of `m`, returning a `MixedModelBootstrap`.

The default random number generator is `Random.GLOBAL_RNG`.

`GeneralizedLinearMixedModel` is currently unsupported.

# Named Arguments

`progress=false` can be used to disable the progress bar. Note that the progress
bar is automatically disabled for non-interactive (i.e. logging) contexts.

`blup_method` provides options for how/which group-level effects are passed for resampling.
The default `ranef` uses the shrunken conditional modes / BLUPs. Unshrunken estimates from
ordinary least squares (OLS) can be used with `olsranef`. There is no shrinkage of the
group-level estimates with this approach, which means singular estimates can be avoided.
However, if the design matrix for the random effects is rank deficient (e.g., through the use
of `MixedModels.fulldummy` or missing cells in the data), then this method will fail.
See [`olsranef`](@ref) and `MixedModels.ranef` for more information.

`residual_method` provides options for how observation-level residuals are passed for permutation.
This should be a two-argument function, taking the model and the BLUPs (as computed with `blup_method`)
as arguments. If you wish to ignore the BLUPs as computed with `blup_method`, then you still need
the second argument, but you can simply not use it in your function.

`inflation_method` is a three-argument function (model, BLUPs as computed by `blup_method`,
residuals computed by `residual_method`) for computing the inflation factor passed onto [`resample!`](@ref).

# Method

The method implemented here is based on the approach given in Section 3.2 of:
Carpenter, J.R., Goldstein, H. and Rasbash, J. (2003).
A novel bootstrap procedure for assessing the relationship between class size and achievement.
Journal of the Royal Statistical Society: Series C (Applied Statistics), 52: 431-443.
https://doi.org/10.1111/1467-9876.00415
"""
function nonparametricbootstrap(rng::AbstractRNG,
                                n::Integer,
                                morig::LinearMixedModel{T};
                                progress=true,
                                β=coef(morig),
                                residual_method=residuals_from_blups,
                                blup_method=ranef,
                                inflation_method=inflation_factor) where {T}
    # XXX should we allow specifying betas and blups?
    #     if so, should we use residuals computed based on those or the observed ones?
    βsc, θsc = similar(morig.β), similar(morig.θ)
    p, k = length(βsc), length(θsc)
    model = deepcopy(morig)

    β_names = (Symbol.(fixefnames(morig))...,)

    blups = blup_method(morig)
    resids = residual_method(morig, blups)
    scalings = inflation_method(morig, blups, resids)

    samp = replicate(n; progress) do
        model = resample!(rng, model; β=β, blups=blups, resids=resids, scalings=scalings)
        refit!(model; progress=false)
        return (objective=model.objective,
                σ=model.σ,
                β=NamedTuple{β_names}(fixef!(βsc, model)),
                se=SVector{p,T}(stderror!(βsc, model)),
                θ=SVector{k,T}(getθ!(θsc, model)))
    end
    return MixedModelBootstrap(samp,
                               # XXX I think I messed up contravariance in upstream....
                               convert(Vector{Union{LowerTriangular{T},Diagonal{T}}},
                                       deepcopy(morig.λ)),
                               getfield.(morig.reterms, :inds),
                               copy(morig.optsum.lowerbd),
                               NamedTuple{Symbol.(fnames(morig))}(map(t -> (t.cnames...,),
                                                                      morig.reterms)))
end

function nonparametricbootstrap(nsamp::Integer, m::LinearMixedModel, args...; kwargs...)
    return nonparametricbootstrap(Random.GLOBAL_RNG, nsamp, m, args...; kwargs...)
end

function nonparametricbootstrap(rng::AbstractRNG, n::Integer,
                                morig::GeneralizedLinearMixedModel; kwargs...)
    throw(ArgumentError("GLMM support is not yet implemented"))
end

function resample!(model::LinearMixedModel, args...; kwargs...)
    return resample!(Random.GLOBAL_RNG, model, args...; kwargs...)
end

"""
    resample!([rng::AbstractRNG,] model::LinearMixedModel;
              β=coef(model), blups=ranef(model), resids=residuals(model,blups)
              scalings=inflation_factor(model))

Simulate and install a new response using resampling at the observational and group level.

At both levels, resampling is done with replacement. At the observational level,
this is resampling of the residuals, i.e. comparable to the step in the classical
nonparametric bootstrap for OLS regression. At the group level, samples are done
jointly for all  terms ("random intercept and random slopes", conditional modes)
associated with a particular level of a blocking factor. For example, the
predicted slope and intercept for a single participant or item are kept together.
This clumping in the resampling procedure is necessary to preserve the original
correlation structure of the slopes and intercepts.

In addition to this resampling step, there is also an inflation step. Due to the
shrinkage associated with the random effects in a mixed model, the variance of the
conditional modes / BLUPs / random intercepts and slopes is less than the variance
estimated by the model and displayed in the model summary or via `MixedModels.VarCorr`.
This shrinkage also impacts the observational level residuals. To compensate for this,
the resampled residuals and groups are scale-inflated so that their standard deviation
matches that of the estimates in the original model. The default inflation factor is
computed using [`inflation_factor`](@ref) on the model.

See also [`nonparametricbootstrap`](@ref) and `MixedModels.simulate!`.

!!! warning
    This method has serious limitations for singular models because resampling from
    a distribution with many zeros (e.g. the random effects components with zero variance)
    will often generate new data with even less variance.

# Reference
The method implemented here is based on the approach given in Section 3.2 of:
Carpenter, J.R., Goldstein, H. and Rasbash, J. (2003).
A novel bootstrap procedure for assessing the relationship between class size and achievement.
Journal of the Royal Statistical Society: Series C (Applied Statistics), 52: 431-443.
https://doi.org/10.1111/1467-9876.00415
"""
function resample!(rng::AbstractRNG, model::LinearMixedModel{T};
        β=coef(model),
        blups=ranef(model),
        resids=residuals(model, blups),
        scalings=inflation_factor(model)) where {T}
    reterms = model.reterms
    y = response(model) # we are now modifying the model

    # sampling with replacement
    sample!(rng, resids, y; replace=true)

    # inflate these to be on the same scale as the empirical variation instead of the MLE
    y .*= last(scalings)

    for (inflation, re, trm) in zip(scalings[2:end], blups, reterms)
    npreds, ngrps = size(re)
    # sampling with replacement
    samp = sample(rng, 1:ngrps, ngrps; replace=true)
    # allocate now to avoid allocating later
    # while taking advantage of LowerTriangular lmul!
    newre = re[:, samp]

    # this just multiplies the Z matrices by the BLUPs
    # and add that to y
    mul!(y, trm, lmul!(last(inflation), newre), one(T), one(T))
    # XXX inflation is resampling invariant -- should we move it out?
    end

    mul!(y, model.X, β, one(T), one(T))

    # mark model as unfitted
    model.optsum.feval = -1

    return model
end


"""

    residuals_from_blups(model::LinearMixedModel{T}, blups::Vector{<:AbstractMatrix{T}})

Compute the residuals of a mixed model using the specified group-level BLUPs/predictors.

This is useful for, e.g., comparing the residuals from a mixed-effects model with shrunken
group-level predictors against a non-shrunken classical OLS model fit within each group.
"""
function residuals_from_blups(model::LinearMixedModel{T},
                              blups::Vector{<:AbstractMatrix{T}}) where {T}
    y = response(model) # we are now modifying the model

    ŷ = zeros(T, length(y))

    for (re, trm) in zip(blups, model.reterms)
        mul!(ŷ, trm, re, one(T), one(T))
    end

    mul!(ŷ, model.X, model.β, one(T), one(T))

    # TODO: do this inplace to avoid an allocation
    return y .- ŷ
end


"""
    inflation_factor(m::LinearMixedModel, blups=ranef(m), resids=residuals(m)))

Compute how much the standard deviation of the BLUPs/conditional modes and residuals
needs to be inflated in order to match the (restricted) maximum-likelihood estimate.

Due to the shrinkage associated with the random effects in a mixed model, the
variance of the conditional modes / BLUPs / random intercepts and slopes is less
than the variance estimated by the model and displayed in the model summary or
via `MixedModels.VarCorr`. This shrinkage also impacts the observational level
residuals. To compensate for this, the resampled residuals and groups need to be
scale-inflated so that their standard deviation matches that of the estimates in
the original model.

The factor for scale inflation is returned as a `Vector` of inflation factors
for each of the random-effect strata (blocking variables) and the observation-level
variability. The factor is on the standard deviation scale (lower Cholesky factor
in the case of vector-valued random effects).
"""
function inflation_factor(m::LinearMixedModel, blups=ranef(m), resids=residuals(m))
    σ = sdest(m)
    σres = std(resids; corrected=false)
    inflation = map(zip(m.reterms, blups)) do (trm, re)
        # inflation
        λmle = trm.λ * σ                              # L_R in CGR

        cov_emp = StatsBase.cov(re'; corrected=false)

        chol = cholesky(cov_emp, RowMaximum(); check=false, tol=10^-5)

        #  ATTEMPT 2
        while chol.rank != size(cov_emp, 1)
            #@info "rep"
            idx = chol.p[(chol.rank + 1):end]
            cov_emp[idx, idx] .+= 1e-6
            chol = cholesky(cov_emp, RowMaximum(); check=false, tol=10^-5)
        end

        L = chol.L[invperm(chol.p), :]
        cov_emp = L * L'
        cov_mle = λmle * λmle'

        return cov_mle / cov_emp
    end
    return [inflation; σ / σres]
end