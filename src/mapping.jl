
function map_locus(geno::AbstractDataFrame, pheno::AbstractVector, 
    contexts::AbstractDataFrame, donor::AbstractVector, 
    batch::Union{AbstractVector, Nothing} = nothing, 
    n::Vector{Int64} = [100, 400, 500, 4000, 5000]; 
    main_effect::Bool = false, return_boot::Bool = false)
    
   # ------------- Validate dimensionality of input data structures ------------- #

    geno_size = nrow(geno)
    pheno_len = length(pheno)
    contexts_size = nrow(contexts)
    donor_len = length(donor)


    n_obs = Dict(:snp => geno_size, :expr => pheno_len, 
                 :contexts => contexts_size, :donor => donor_len)

    if !isnothing(batch)
        n_obs[:batch] =  length(batch)
    end
   
   n_obs_vals  = collect(values(n_obs))

   if(!all(x -> x == first(n_obs_vals), n_obs_vals))
       
       println("Verify number of observatios of input files")
       println("Number of observations per input data\n")
       for (key, value) in pairs(n_obs)
           println(key, " = ", value)
           
       end
       throw("Number of observations in input data do not match between input files")
       
   end

   # ------------------ Validate number of bootstrap iterations ----------------- #

   if length(n) != length(unique(n))

    throw("`n` must not contain duplicated values")
   
   end

   # ------------------------------ Integrate data ------------------------------ #

   design = DataFrame(E = pheno, donor = CategoricalArray(donor))

   if !isnothing(batch)
        design[!, :batch] = CategoricalArray(batch)
   end

   # Add contexts
   context_names = names(contexts)

   for col_name in context_names
       design[!, col_name] = contexts[!, col_name]
   end

   # ------------- Define modelling formula and bootstrapping terms ------------- #

   # Add fixed effects
   ## Add main effect and interactions
   f = term(:G) * sum(term.(context_names))

   # Add random effects
   ## Add donor effect
   f = f + (term(1) | term(:donor))

   ## Add batch effect to formula if any
   if !isnothing(batch)
        f = f + (term(1) | term(:batch))
   end
   
   f = FormulaTerm(term(:E), f)

   # ------------------------ Create bootstrapping terms ------------------------ #
  
   boot_terms = Symbol.("G & " .* string.(context_names))

   if main_effect
        pushfirst!(boot_terms, :G)
   end

   # ------------ Run association for each SNP in input genotype data ----------- #

   
   results = pmap(eachcol(geno)) do snp
        boot_snp(f, snp, design, boot_terms, n, return_boot)
   end
   
   # Extract results
   res = Dict{Symbol, Union{DataFrame, Vector{DataFrame}}}(
    :coefs => vcat([x[:coefs] for x in results]...),
    :p     => vcat([x[:p] for x in results]...)
    )

    # Add SNP names to results
    insertcols!(res[:p], 1, :snp => names(geno))
    insertcols!(res[:coefs], 1, :snp => names(geno))

    if return_boot
        res[:boot] = [x[:boot] for x in results]
    end



   return(res)


end






function boot_snp(f::FormulaTerm, snp::AbstractVector, data::AbstractDataFrame, 
    boot_terms::Vector{Symbol}, boot_sizes::Vector{Int64}, return_boot::Bool = false)

    # ------------------------------- Add genotypes ------------------------------ #

    data[!, :G] = snp

    # ------------------- Compute betas and variance components ------------------ #

    # Fit model
    model = fit(MixedModel, f, data)
    
    # Extract betas and variance components
    coefs = DataFrame([model.betas])
    
    sigmas = vcat([x[1] for x in model.sigmas], model.sigma)
    var_values = sigmas.^2
    sigmas_names = vcat(collect(string.(keys(model.sigmas))), "residual")
    sigmas_names = Symbol.("var_" .* sigmas_names)

    # Merge betas and variance components
    re_var = DataFrame(transpose(var_values), sigmas_names)
    coefs = hcat(coefs, re_var)

    # ----------------------- Start adaptive bootstrapping ----------------------- #

    boot = DataFrame()

    for n in boot_sizes
       
        boot_i = boot_model(MersenneTwister(n), data, f, n)
        boot_i = reduce(vcat, boot_i)

        # Combine with prebious results
        boot = vcat(boot, boot_i)
        # Return logical vector specifying which parameters pass
        # condition
        param_status = map(count_nonzeros, eachcol(boot[:, boot_terms]))
        # Stop bootstrapping if more than 20 values cross zero
        if(all(param_status .> 20))
            break
        end

    end

    boot = boot[:, boot_terms]

    p_vals = zeros(length(boot_terms))
    for i in 1:length(boot_terms)
        p_vals[i] = basic_p(coefs[1, boot_terms][i], boot[:, i])
    end

    p_vals = DataFrame(transpose(p_vals), names(boot))

    res = Dict(:coefs => coefs, :p => p_vals)

    if return_boot
        res[:boot] = boot
    end

    return(res)

end
