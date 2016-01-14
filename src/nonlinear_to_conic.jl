# wrapper to convert Nonlinear solver into Conic solver
# The translation is lossy...
# Authors: Emre Yamangil and Miles Lubin

type NonlinearToConicBridge <: MathProgBase.AbstractConicModel
    solution::Vector{Float64}
    status
    objval::Float64
    nlp_solver::MathProgBase.AbstractNonlinearModel
    x
    numVar
    numConstr
    nlp_model
    function NonlinearToConicBridge(nlp_solver)
        m = new()
        m.nlp_solver = nlp_solver
        return m
    end
end 

export ConicNLPWrapper
immutable ConicNLPWrapper <: MathProgBase.AbstractMathProgSolver
    nlp_solver::MathProgBase.AbstractMathProgSolver
end
MathProgBase.ConicModel(s::ConicNLPWrapper) = NonlinearToConicBridge(s.nlp_solver)

function MathProgBase.loadproblem!(
    m::NonlinearToConicBridge, c, A, b, constr_cones, var_cones)

    nlp_model = Model(solver=m.nlp_solver)
    numVar = length(c) # number of variables
    numConstr = length(b) # number of constraints

    # b - Ax \in K => b - Ax = s, s \in K
    new_var_cones = Any[x for x in var_cones]
    new_constr_cones = Any[]
    copy_constr_cones = copy(constr_cones)
    lengthSpecCones = 0
    # ADD SLACKS FOR ONLY SOC AND EXP
    A_I, A_J, A_V = findnz(A)
    slack_count = numVar+1
    for (cone, ind) in copy_constr_cones
        if cone == :SOC || cone == :ExpPrimal
            lengthSpecCones += length(ind)
            slack_vars = slack_count:(slack_count+length(ind)-1)
            append!(A_I, ind)
            append!(A_J, slack_vars)
            append!(A_V, ones(length(ind)))
            
            push!(new_var_cones, (cone, slack_vars))
            push!(new_constr_cones, (:Zero, ind))
            slack_count += length(ind)
        else
            push!(new_constr_cones, (cone, ind))
        end
    end
    A = sparse(A_I,A_J,A_V, numConstr, numVar + lengthSpecCones)

    m.numVar = size(A,2)
    m.numConstr = numConstr 
    c = [c;zeros(m.numVar-numVar)]

    # LOAD NLP MODEL
    @defVar(nlp_model, x[i=1:m.numVar], start = 1)
    
    @setObjective(nlp_model, Min, dot(c,x))

    for (cone, ind) in new_var_cones
        if cone == :Zero
            for i in ind
                setLower(x[i], 0.0)
                setUpper(x[i], 0.0)
            end
        elseif cone == :Free
            # do nothing
        elseif cone == :NonNeg
            for i in ind
                setLower(x[i], 0.0)
            end
        elseif cone == :NonPos
            for i in ind
                setUpper(x[i], 0.0)
            end
        elseif cone == :SOC
            @addNLConstraint(nlp_model, sqrt(sum{x[i]^2, i in ind[2:length(ind)]}) <= x[ind[1]])
            setLower(x[ind[1]], 0.0)
        elseif cone == :ExpPrimal
            @addNLConstraint(nlp_model, x[ind[2]] * exp(x[ind[1]]/x[ind[2]]) <= x[ind[3]])
            setLower(x[ind[2]], 0.0)
            setLower(x[ind[3]], 0.0)
        end
    end

    # *************** PREPROCESS *******************
    constr_cones_map = [:NoCone for i in 1:numConstr]
    for (cone, ind) in new_constr_cones
        constr_cones_map[ind] = cone
    end

    nonZeroElements = [Any[] for i in 1:numConstr] # by row
    for i in 1:length(A_I)
        push!(nonZeroElements[A_I[i]], (A_J[i], A_V[i]))
    end
    remRowInd = Any[]
    rowIndicator = [false for i in 1:numConstr]
    for i in 1:numConstr
        if length(nonZeroElements[i]) == 1
            (ind, val) = nonZeroElements[i][1]
            #@show full(A[i,:])
            #@show b[i]
            #@show ind, val
            if constr_cones_map[i] == :Zero
                setLower(x[ind], b[i]/val)
                setUpper(x[ind], b[i]/val)
                #println("x[$ind] == $(b[i]/val)")
            elseif constr_cones_map[i] == :NonNeg
                if val < 0.0
                    setLower(x[ind], b[i]/val)
                else
                    setUpper(x[ind], b[i]/val)
                    #println("x[$ind] <= $(b[i]/val)")
                end
            elseif constr_cones_map[i] == :NonPos
                if val < 0.0
                    setUpper(x[ind], b[i]/val)
                else
                    setLower(x[ind], b[i]/val)
                    #println("x[$ind] >= $(b[i]/val)")
                end
            else
                error("!!!!")
            end
        else
            rowIndicator[i] = true
            push!(remRowInd, i)
        end
    end

    rowIndicator = [true for i in 1:numConstr]
    for (cone,ind) in new_constr_cones
        for i in 1:length(ind)
            if rowIndicator[ind[i]]
                if cone == :Zero
                    @addConstraint(nlp_model, A[ind[i]:ind[i],:]*x .== b[ind[i]])
                elseif cone == :NonNeg
                    @addConstraint(nlp_model, A[ind[i]:ind[i],:]*x .<= b[ind[i]])
                elseif cone == :NonPos
                    @addConstraint(nlp_model, A[ind[i]:ind[i],:]*x .>= b[ind[i]])
                else
                    error("unrecognized cone $cone")
                end
            end
        end
    end

    m.x = x
    m.numVar = numVar
    m.nlp_model = nlp_model

end

function MathProgBase.optimize!(m::NonlinearToConicBridge)
 
    m.status = solve(m.nlp_model)
    m.objval = getObjectiveValue(m.nlp_model)
    m.solution = getValue(m.x)

end

MathProgBase.supportedcones(s::ConicNLPWrapper) = [:Free,:Zero,:NonNeg,:NonPos,:SOC,:ExpPrimal]

MathProgBase.setwarmstart!(m::NonlinearToConicBridge, x) = (m.solution = x)
MathProgBase.setvartype!(m::NonlinearToConicBridge, v::Vector{Symbol}) = (m.vartype = v)

MathProgBase.status(m::NonlinearToConicBridge) = m.status
MathProgBase.getobjval(m::NonlinearToConicBridge) = m.objval
MathProgBase.getsolution(m::NonlinearToConicBridge) = m.solution
