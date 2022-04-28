getidx(dag::IntentDAG) = dag.graph_data.idx
function addchild!(idag::IntentDAG, intent::I) where I<:Intent
    state = intent isa LowLevelIntent ? compiled : uncompiled
    childnode = IntentDAGNode(intent, state, uuidlast(idag))
    add_vertex!(idag, uuidlast(idag), childnode) || return false
    uuidpp(idag)
    return childnode
end

function addchild!(idag::IntentDAG, parent::UUID, child::I) where I<:Intent
    parentnode = idag[parent]
    state = child isa LowLevelIntent ? compiled : uncompiled
    childnode = IntentDAGNode(child, state, uuidlast(idag))
    add_vertex!(idag, uuidlast(idag), childnode) || return false
    add_edge!(idag, parent, uuidlast(idag), nothing) || return false
    uuidpp(idag)
    return childnode
end

function uuidpp(idag::IntentDAG)
    idag.graph_data.intentcounter += 1
    return UUID(idag.graph_data.intentcounter)
end
uuidlast(idag::IntentDAG) = UUID(idag.graph_data.intentcounter)
getroot(idag::IntentDAG) = return idag[UUID(1)]

function isintraintent(ibn::IBN, intent::ConnectivityIntent)
    if getid(ibn) == getsrc(intent)[1] == getdst(intent)[1]
        return true
    elseif getid(ibn) == getsrcdom(intent)
        return getdst(intent) in transnodes(ibn)
    elseif getid(ibn) == getdstdom(intent)
        return getsrc(intent) in transnodes(ibn)
    else
        return false
    end
end

function setstate!(idn, dag, ibn::IBN, newstate::IntentState)
    if newstate == compiled
        setstate!(idn, dag, ibn, Val(compiled))
    elseif newstate == installed
        setstate!(idn, dag, ibn, Val(installed))
    else
        idn.state = newstate
    end
end


"""propagate state in the DAG
"compiled" and "installed" states start only from `LowLevelIntents` and propagte the tree up to the root
"""
function setstate!(idn::IntentDAGNode, dag::IntentDAG, ibn::IBN, newstate::Val{compiled})
    idn.state = compiled
    if isroot(dag, idn)
        intentissuer = ibn.intentissuers[getidx(dag)]
        if intentissuer isa IBNIssuer
            ibnid = intentissuer.ibnid
            ibncustomer = getibn(ibn, ibnid)
            setstate!(ibncustomer, ibn, getid(ibn), getidx(dag), compiled)
        end
    else
        for par in parents(dag, idn)
            try2setstate!(par, dag, ibn, Val(compiled))
        end
    end
end

function setstate!(idn::IntentDAGNode, dag::IntentDAG, ibn::IBN, newstate::Val{installed})
    idn.state = installed
    if isroot(dag, idn)
        intentissuer = ibn.intentissuers[getidx(dag)]
        if intentissuer isa IBNIssuer
            ibnid = intentissuer.ibnid
            ibncustomer = getibn(ibn, ibnid)
            setstate!(ibncustomer, ibn, getid(ibn), getidx(dag), installed)
        end
    else
        for par in parents(dag, idn)
            try2setstate!(par, dag, ibn, Val(installed))
        end
    end
end

setstate!(idn::IntentDAGNode, dag::IntentDAG, ibn, newstate::Val{installing}) = (idn.state = installing)
setstate!(idn::IntentDAGNode, dag::IntentDAG, ibn, newstate::Val{installfailed}) = (idn.state = installfailed)

"""
Checks all children of `idn` and if all are compiled, `idn` is getting in the compiled state also.
If not, it gets in the `compiling` state.
"""
function try2setstate!(idn::IntentDAGNode, dag::IntentDAG, ibn::IBN, newstate::Val{compiled})
    descs = descendants(dag, idn)
    if all(x -> x.state == compiled, descs)
        setstate!(idn, dag, ibn, Val(compiled))
    else
        setstate!(idn, dag, ibn, Val(compiling))
    end
end

"""
Checks all children of `idn` and if all are installed, `idn` is getting in the installed state also.
If not, it gets in the `installing` state.
"""
function try2setstate!(idn::IntentDAGNode, dag::IntentDAG, ibn::IBN, newstate::Val{installed})
    descs = descendants(dag, idn)
    if all(x -> x.state == installed, descs)
        setstate!(idn, dag, ibn, Val(installed))
    else
        setstate!(idn, dag, ibn, Val(installing))
    end
end

"get all nodes with the same parent"
siblings(idn::IntentDAGNode, dag::IntentDAG, paruuid=nothing) = error("not implemented")

function parents(dag::IntentDAG, idn::IntentDAGNode)
    return [dag[MGN.label_for(dag, v)] for v in inneighbors(dag, MGN.code_for(dag, idn.id))]
end

function children(dag::IntentDAG, idn::IntentDAGNode)
    return [dag[MGN.label_for(dag, v)] for v in outneighbors(dag, MGN.code_for(dag, idn.id))]
end

isroot(dag::IntentDAG, idn::IntentDAGNode) = length(inneighbors(dag, MGN.code_for(dag, idn.id))) == 0
haschildren(dag::IntentDAG, idn::IntentDAGNode) = length(outneighbors(dag, MGN.code_for(dag, idn.id))) > 0

getleafs(dag::IntentDAG) = getleafs(dag, getroot(dag))
function getleafs(dag::IntentDAG, idn::IntentDAGNode)
    idns = Vector{IntentDAGNode}()
    for chidn in children(dag, idn)
        _leafs_recu!(idns, dag, chidn)
    end
    return idns
end

descendants(dag::IntentDAG) = descendants(dag, getroot(dag))
function descendants(dag::IntentDAG, idn::IntentDAGNode)
    idns = Vector{IntentDAGNode}()
    for chidn in children(dag, idn)
        _descendants_recu!(idns, dag, chidn)
    end
    return idns
end

function _leafs_recu!(vidns::Vector{IntentDAGNode}, dag::IntentDAG, idn::IntentDAGNode)
    if haschildren(dag, idn)
        for chidn in children(dag, idn)
            _leafs_recu!(vidns, dag, chidn)
        end
    else
        push!(vidns, idn)
    end
end

function _descendants_recu!(vidns::Vector{IntentDAGNode}, dag::IntentDAG, idn::IntentDAGNode)
    push!(vidns, idn)
    for chidn in children(dag, idn)
        _descendants_recu!(vidns, dag, chidn)
    end
end
