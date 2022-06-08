#=
# This is supposed to be a simplified version of an Intent Language System
=#
newintent(intent::ConnectivityIntent) = ConnectivityIntent(getsrc(intent), getdst(intent), getconstraints(intent), 
                                                           getconditions(intent))
getintentidx(idag::IntentDAG) = idag.graph_data.idx
getintentdagnodes(dag::IntentDAG) = Base.getindex.(values(dag.vertex_properties), 2)
getnode(i::Intent) = i.node

convert2global(ibn::IBN, lli::NodeSpectrumIntent{Int, E}) where 
    E<:Edge = NodeSpectrumIntent(globalnode(ibn, lli.node), globaledge(ibn, lli.edge), lli.slots, lli.bandwidth)

convert2global(ibn::IBN, lli::NodeRouterIntent{Int}) = 
    NodeRouterIntent(globalnode(ibn, lli.node), lli.ports)

"Return global intent index"
function intentidx(ibn::IBN, dag::IntentDAG, idn::R=missing) where R <: Union{IntentDAGNode, Missing}
    ibnid = getid(ibn)
    dagidx = getidx(dag)
    if idn === missing
        idnuid = getid(getroot(idn))
    else
        idnuid = getid(idn)
    end
    return (ibnid, dagidx, idnuid)
end

function getfirstdagnode_fromintent(dag::IntentDAG, intent::Intent)
    for idn in getintentdagnodes(dag)
        if getintent(idn) == intent
            return idn
        end
    end
end

#tdl
function getsymmetricintent(nsi::R) where R<:NodeSpectrumIntent
    if nsi.node == src(nsi.edge)
        nod = dst(nsi.edge)
    else
        nod = src(nsi.edge)
    end
    return NodeSpectrumIntent(nod, nsi.edge, nsi.slots, nsi.bandwidth)
end

function adjustNpropagate_constraints!(ibn::IBN, dag::IntentDAG, idn::IntentDAGNode{R}) where R<:PathIntent
    constraints = getconstraints(getintent(idn))
    propagete_constraints = Vector{IntentConstraint}()
    for (i,constr) in enumerate(constraints)
        if constr isa DelayConstraint
            #readjust intent
            mydelay = delay(distance(ibn, getintent(idn).path))
            constraints[i] = DelayConstraint(mydelay)
            
            push!(propagete_constraints, DelayConstraint(constr.delay - mydelay))
        else
            push!(propagete_constraints, constr)
        end
    end
    return propagete_constraints
end

function getcompliantintent(ibn::IBN, parint::I, ::Type{PathIntent}, path::Vector{Int}) where {I<:Intent}
    dc = getfirst(x -> x isa DelayConstraint, parint.constraints)
    if dc !== nothing
        if delay(distance(ibn, path)) > dc.delay
             return nothing
         end
    end
    return PathIntent(path, filter(x -> !(x isa DelayConstraint), parint.constraints))
end
function getcompliantintent(ibn::IBN, parint::I, ::Type{SpectrumIntent}, path::Vector{Int}, drate::Float64, sr::UnitRange{Int}) where {I<:Intent}
    cc = getfirst(x -> x isa CapacityConstraint, parint.constraints)
    if cc !== nothing
        if cc.drate > drate
             return nothing
         end
    end
    return SpectrumIntent(path, drate, sr, filter(x -> !(x isa CapacityConstraint), parint.constraints))
end

"""
Convert `intent` from `ibn1` to constraint for the neighbor IBN
returns a Pair{neighbor ibn id, intent constraint}
"""
function intent2constraint(intent::R, ibn::IBN) where R<:NodeRouterIntent
    if getnode(intent) in transnodes(ibn, subnetwork_view=false)
        cnode = ibn.cgr.vmap[getnode(intent)]
        contr = ibn.controllers[cnode[1]]
        if contr isa IBN
            ibnid = getid(contr)
        else
            error("Transode has not an IBN controller")
        end
        return Pair(ibnid, GoThroughConstraint((ibnid, cnode[2]), signalElectrical))
    end
end

"assumes only one node is in another ibn"
function intent2constraint(intent::R, ibn::IBN) where R<:NodeSpectrumIntent
    if getnode(intent) in transnodes(ibn, subnetwork_view=false)
        cnode = ibn.cgr.vmap[getnode(intent)]
        contr = ibn.controllers[cnode[1]]
        if contr isa IBN
            ibnid = getid(contr)
        else
            error("Transode has not an IBN controller")
        end
        if src(intent.edge) in transnodes(ibn, subnetwork_view=false)
            csrc = (ibnid, cnode[2])
            cdst = (getid(ibn), dst(intent.edge))
            cedg = CompositeEdge(csrc, cdst)
            return Pair(ibnid, GoThroughConstraint((ibnid, cnode[2]), signalFiberOut, SpectrumRequirements(cedg, intent.slots, intent.bandwidth)))
        else
            cdst = (ibnid, cnode[2])
            csrc = (getid(ibn), src(intent.edge))
            cedg = CompositeEdge(csrc, cdst)
            return Pair(ibnid, GoThroughConstraint((ibnid, cnode[2]), signalFiberIn, SpectrumRequirements(cedg, intent.slots, intent.bandwidth)))
        end
    end
end


"Path needs to be completely inside the IBN"
function isavailable(ibn::IBN, dag::IntentDAG, pathint::T) where {T<:PathIntent}
    path = pathint.path
    sdn1 = controllerofnode(ibn, path[1])
    sdn2 = controllerofnode(ibn, path[end])
    if sdn1 isa SDN && sdn2 isa SDN
        src = ibn.cgr.vmap[path[1]][2]
        dst = ibn.cgr.vmap[path[end]][2]
        return isavailable_port(sdn1, src) && isavailable_port(sdn2, dst)
    elseif sdn1 isa SDN
        # only consider intradomain knowledge. assume it's possible for the other domain
        src = ibn.cgr.vmap[path[1]][2]
        return isavailable_port(sdn1, src)
    elseif sdn2 isa SDN
        # only consider intradomain knowledge. assume it's possible for the other domain
        dst = ibn.cgr.vmap[path[end]][2]
        return isavailable_port(sdn2, dst)
    end
    return false
end

function isavailable(ibn::IBN, dag::IntentDAG, speint::T) where {T<:SpectrumIntent}
    success = false
    for e in edgeify(speint.lightpath)
        ce = CompositeGraphs.compositeedge(ibn.cgr, e)
        sdn1 = controllerofnode(ibn, e.src)
        sdn2 = controllerofnode(ibn, e.dst)
        if sdn1 isa SDN && sdn2 isa SDN
            return isavailable_slots(sdn1, ce, speint.spectrumalloc)
        elseif sdn1 isa SDN
            # only consider intradomain knowledge. assume it's possible for the other domain
            return isavailable_slots(sdn1, ce, speint.spectrumalloc)
        elseif sdn2 isa SDN
            # only consider intradomain knowledge. assume it's possible for the other domain
            return isavailable_slots(sdn2, ce, speint.spectrumalloc)
        end
    end
    return success
end

function sdnspace(ibn::IBN, dag::IntentDAG, idn::IntentDAGNode) 
    intent = getintent(idn)
    sdn = controllerofnode(ibn, intent.node)
    sdnode = ibn.cgr.vmap[intent.node][2]
    return (intent, sdn, sdnode)
end
function intersdnspace(ibn::IBN, dag::IntentDAG, idn::IntentDAGNode) 
    intent = getintent(idn)
    ce = CompositeGraphs.compositeedge(ibn.cgr, intent.edge)
    sdn1 = controllerofnode(ibn, intent.edge.src)
    sdn2 = controllerofnode(ibn, intent.edge.dst)
    return (intent, ce, sdn1, sdn2)
end

function isavailable(ibn::IBN, dag::IntentDAG, nri::IntentDAGNode{R}) where R <:NodeRouterIntent
    intent, sdn, sdnode = sdnspace(ibn, dag, nri)
    return isavailable_port(sdn, sdnode)
end

function reserve(ibn::IBN, dag::IntentDAG, nri::IntentDAGNode{R}) where R <:NodeRouterIntent
    intent, sdn, sdnode = sdnspace(ibn, dag, nri)
    return reserve_port!(sdn, sdnode, (getid(ibn), getintentidx(dag), getid(nri)))
end
function free!(ibn::IBN, dag::IntentDAG, nri::IntentDAGNode{R}) where R <:NodeRouterIntent
    intent, sdn, sdnode = sdnspace(ibn, dag, nri)
    return free_port!(sdn, sdnode, (getid(ibn), getintentidx(dag), getid(nri)))
end

function issatisfied(ibn::IBN, dag::IntentDAG, nri::IntentDAGNode{R}) where R <:NodeRouterIntent
    intent, sdn, sdnode = sdnspace(ibn, dag, nri)
    return issatisfied_port(sdn, sdnode, (getid(ibn), getintentidx(dag), getid(nri)))
end

function isavailable(ibn::IBN, dag::IntentDAG, nsi::IntentDAGNode{R}) where R <:NodeSpectrumIntent
    intent, ce, sdn1, sdn2 = intersdnspace(ibn, dag, nsi)
    reserve_src = ibn.cgr.vmap[intent.node] == ce.src ? true : false
    sdn = sdn1 isa SDN ? sdn1 : sdn2
    if sdn isa SDN
        return isavailable_slots(sdn, ce, intent.slots, reserve_src)
    end
    return false
end

function reserve(ibn::IBN, dag::IntentDAG, nsi::IntentDAGNode{R}) where R <:NodeSpectrumIntent
    intent, ce, sdn1, sdn2 = intersdnspace(ibn, dag, nsi)
    reserve_src = ibn.cgr.vmap[intent.node] == ce.src ? true : false
    sdn = sdn1 isa SDN ? sdn1 : sdn2
    if sdn isa SDN
        return reserve_slots!(sdn, ce, intent.slots, (getid(ibn), getintentidx(dag), getid(nsi)), reserve_src)
    end
    return false
end
function free!(ibn::IBN, dag::IntentDAG, nsi::IntentDAGNode{R}) where R <:NodeSpectrumIntent
    intent, ce, sdn1, sdn2 = intersdnspace(ibn, dag, nsi)
    reserve_src = ibn.cgr.vmap[intent.node] == ce.src ? true : false
    sdn = sdn1 isa SDN ? sdn1 : sdn2
    if sdn isa SDN
        return free_slots!(sdn, ce, intent.slots, (getid(ibn), getintentidx(dag), getid(nsi)), reserve_src)
    end
    return false
end

function issatisfied(ibn::IBN, dag::IntentDAG, nsi::IntentDAGNode{R}) where R <:NodeSpectrumIntent
    intent, ce, sdn1, sdn2 = intersdnspace(ibn, dag, nsi)
    reserve_src = ibn.cgr.vmap[intent.node] == ce.src ? true : false
    sdn = sdn1 isa SDN ? sdn1 : sdn2
    if sdn isa SDN
        issatisfied_slots!(sdn, ce, intent.slots, (getid(ibn), getintentidx(dag), getid(nsi)), reserve_src) && return true
    end
    return false
end

has_extendedchildren(intr::IntentDAG) = (getcompilation(intr) isa RemoteIntentCompilation) || AbstractTrees.has_children(intr)
#function extendedchildren(intr::IntentDAG)
#    if getcompilation(intr) isa RemoteIntentCompilation
#        comp = getcompilation(intr)
#        return [comp.remoteibn.intents[comp.intentidx]]
#    elseif AbstractTrees.has_children(intr)
#        return children(intr)
#    else
#        return IntentDAG[]
#    end
#end
#"Assuming that `intr` belongs to `ibn`, return extended children together with the corresponding ibn"
#function extendedchildren(ibn::IBN, intr::IntentDAG)
#    if getcompilation(intr) isa RemoteIntentCompilation
#        comp = getcompilation(intr)
#        return zip(Iterators.repeated(comp.remoteibn),[comp.remoteibn.intents[comp.intentidx]])
#    elseif AbstractTrees.has_children(intr)
#        return zip(Iterators.repeated(ibn), children(intr))
#    end
#end

function push_extendedchildren!(intents, ibn::IBN, intr::IntentDAG; ibnidfilter::Union{Nothing, Int}=nothing)
    if has_extendedchildren(intr)
        for (nextibn, chintentr) in extendedchildren(ibn,intr)
            if getid(nextibn) == ibnidfilter
                push!(intents, chintentr.data)
            end
            push_extendedchildren!(intents, nextibn, chintentr; ibnidfilter=ibnidfilter)
        end
    end
end
function push_extendedchildren!(ibnintd::Dict{Int, Vector{Intent}}, ibn::IBN, intr::IntentDAG)
    if has_extendedchildren(intr)
        for (nextibn, chintentr) in extendedchildren(ibn,intr)
            if !haskey(ibnintd, getid(nextibn))
                ibnintd[getid(nextibn)] = Vector{Intent}()
            end
            push!(ibnintd[getid(nextibn)], chintentr.data)
            push_extendedchildren!(ibnintd, nextibn, chintentr)
        end
    end
end
function push_extendedchildren!(intents, intr::IntentDAG)
    if has_extendedchildren(intr)
        for chintentr in extendedchildren(intr)
            push!(intents, chintentr.data)
            push_extendedchildren!(intents, chintentr)
        end
    end
end
function recursive_children!(intents, intr::IntentDAG)
    if AbstractTrees.has_children(intr)
        for chintentr in children(intr)
            push!(intents, chintentr.data)
            recursive_children!(intents, chintentr)
        end
    end
end
#function descendants(intr::IntentDAG)
#    intents = Vector{Intent}()
#    push!(intents, intr.data)
#    push_extendedchildren!(intents, intr)
#    return intents
#end
function family(ibn::IBN, intidx::Int; intraibn::Bool=false, ibnidfilter::Union{Nothing, Int}=nothing)
    intents = Vector{Intent}()
    if intraibn
        if ibnidfilter === nothing || ibnidfilter == getid(ibn)
            return intents
        else
            push!(intents, ibn.intents[intidx].data)
            recursive_children!(intents, ibn.intents[intidx])
        end
    else
        if ibnidfilter === nothing || ibnidfilter == getid(ibn)
            push!(intents, ibn.intents[intidx].data)
        end
        push_extendedchildren!(intents, ibn, ibn.intents[intidx]; ibnidfilter=ibnidfilter)
    end
    return intents
end

function dividefamily(ibn::IBN, intidx::Int)
    ibnintd = Dict{Int, Vector{Intent}}()
    ibnintd[getid(ibn)] = Vector{Intent}([ibn.intents[intidx].data])
    push_extendedchildren!(ibnintd, ibn, ibn.intents[intidx])
    return ibnintd
end

#function edgeify(intents::Vector{Intent}, ::Type{R}) where R<:IntentCompilation
#    concomps = [getcompilation(intent) for intent in intents if getcompilation(intent) isa ConnectivityIntentCompilation]
#    paths = [getfield(concomp, :path) for concomp in concomps]
#    return [edgeify(path) for path in paths]
#end
#
#"""
#Takes input all available IBNs
#Prints out a full Intent Tree across all of them
#"""
#function print_tree_extended(intr::IntentDAG, maxdepth=5)
#    p = getpair(intr)
#    print_tree(p, maxdepth=maxdepth)
#end
#
#function getextendedchildrenpair(intr::IntentDAG)
#    if getcompilation(intr) isa RemoteIntentCompilation
#        comp = getcompilation(intr)
#        getpair(comp.remoteibn.intents[comp.intentidx])
#    elseif AbstractTrees.has_children(intr)
#        getpair.(children(intr))
#    else
#        return intr
#    end
#end
#
#function getpair(intr::IntentDAG)
#    if !has_extendedchildren(intr)
#        return intr
#    else
#        return Pair(intr, getextendedchildrenpair(intr))
#    end
#end
#
