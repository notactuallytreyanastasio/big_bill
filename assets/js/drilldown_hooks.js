// Section text container — handles clicks on linkified section references
export const SectionText = {
  mounted() { this._bind() },
  updated() { this._bind() },
  _bind() {
    this.el.addEventListener("click", (e) => {
      const link = e.target.closest("[data-section]")
      if (link) {
        e.preventDefault()
        e.stopPropagation()
        const sec = link.dataset.section
        // Scroll to top of container when navigating to a new section
        this.el.scrollTop = 0
        this.pushEvent("preview_section", {sec: sec})
      }
    })
  }
}

// Load D3 dynamically from static vendor file — avoids esbuild UMD bundling issues
let d3 = null
let d3Loading = null

function ensureD3() {
  if (d3) return Promise.resolve(d3)
  if (window.d3) { d3 = window.d3; return Promise.resolve(d3) }
  if (d3Loading) return d3Loading
  d3Loading = new Promise((resolve) => {
    const s = document.createElement("script")
    s.src = "/vendor/d3.min.js"
    s.onload = () => { d3 = window.d3; resolve(d3) }
    document.head.appendChild(s)
  })
  return d3Loading
}

// Entity chart — diverging horizontal bar chart (benefits vs loses)
export const EntityChart = {
  mounted() {
    this.handleEvent("entity_data", ({entities}) => {
      ensureD3().then(() => this.renderChart(entities))
    })
  },

  renderChart(entities) {
    const el = this.el
    const hook = this
    el.innerHTML = ""

    if (!entities || entities.length === 0) {
      el.innerHTML = '<p class="text-gray-400 text-center py-8">No entity data for this scope</p>'
      return
    }

    const agg = {}
    entities.forEach(e => {
      const key = e.entity_name
      if (!agg[key]) agg[key] = {name: key, type: e.entity_type, benefits: 0, loses: 0, details: []}
      if (e.outcome === "benefits") agg[key].benefits++
      else if (e.outcome === "loses") agg[key].loses++
      agg[key].details.push({section_number: e.section_number, outcome: e.outcome, detail: e.detail})
    })

    let data = Object.values(agg)
      .map(d => ({...d, net: d.benefits - d.loses, total: d.benefits + d.loses}))
      .sort((a, b) => Math.abs(b.net) - Math.abs(a.net))
      .slice(0, 30)

    const width = Math.max(el.clientWidth, 1400)
    const barHeight = 36
    const margin = {top: 50, right: 140, bottom: 20, left: 240}
    const height = margin.top + margin.bottom + data.length * barHeight

    const svg = d3.select(el).append("svg")
      .attr("width", "100%")
      .attr("height", height)
      .attr("viewBox", `0 0 ${width} ${height}`)
      .attr("preserveAspectRatio", "xMidYMid meet")

    // Use sqrt scale so Treasury doesn't crush everything else
    const maxAbs = d3.max(data, d => Math.max(d.benefits, d.loses)) || 1
    const xRight = d3.scaleSqrt().domain([0, maxAbs]).range([0, (width - margin.left - margin.right) / 2])
    const xCenter = margin.left + (width - margin.left - margin.right) / 2
    const x = v => v >= 0 ? xCenter + xRight(v) : xCenter - xRight(-v)

    const y = d3.scaleBand()
      .domain(data.map(d => d.name))
      .range([margin.top, height - margin.bottom])
      .padding(0.25)

    // Zero line
    svg.append("line")
      .attr("x1", xCenter).attr("x2", xCenter)
      .attr("y1", margin.top).attr("y2", height - margin.bottom)
      .attr("stroke", "#94a3b8").attr("stroke-width", 1)

    // Column headers
    svg.append("text").attr("x", xCenter - (width - margin.left - margin.right) / 4).attr("y", margin.top - 12)
      .attr("text-anchor", "middle").attr("fill", "#dc2626")
      .attr("font-size", "12px").attr("font-weight", "600").text("LOSES")
    svg.append("text").attr("x", xCenter + (width - margin.left - margin.right) / 4).attr("y", margin.top - 12)
      .attr("text-anchor", "middle").attr("fill", "#16a34a")
      .attr("font-size", "12px").attr("font-weight", "600").text("BENEFITS")

    // Tooltip
    el.style.position = "relative"
    const tip = d3.select(el).append("div")
      .style("position", "absolute").style("pointer-events", "none").style("opacity", 0)
      .style("transition", "opacity 0.15s")
      .attr("class", "bg-gray-900 text-white text-xs rounded-lg shadow-xl p-4 max-w-sm z-50 leading-relaxed")

    function showEntityTip(event, d) {
      const details = d.details || []
      const secs = [...new Set(details.map(x => x.section_number))].slice(0, 8)
      tip.html(`
        <div class="font-semibold text-sm mb-1">${d.name}</div>
        <span class="text-gray-400">${d.type}</span>
        <div class="flex gap-3 mt-2 mb-2">
          <span class="text-green-400 font-bold">${d.benefits} benefit${d.benefits !== 1 ? 's' : ''}</span>
          <span class="text-red-400 font-bold">${d.loses} lose${d.loses !== 1 ? 's' : ''}</span>
        </div>
        <div class="text-gray-400 text-[10px]">Sections: ${secs.map(s => '§' + s).join(', ')}${details.length > 8 ? '...' : ''}</div>
        <div class="text-blue-400 mt-1">Click for details</div>
      `)
      const rect = el.getBoundingClientRect()
      tip.style("left", Math.min(event.clientX - rect.left + 12, width - 320) + "px")
        .style("top", (event.clientY - rect.top - 10) + "px")
        .style("opacity", 1)
    }
    function hideTip() { tip.style("opacity", 0) }

    // Detail panel for clicked entity
    const detailDiv = d3.select(el).append("div")
      .style("position", "absolute").attr("class", "hidden top-4 right-4 w-[420px] max-h-[80%] bg-white rounded-xl shadow-2xl border border-gray-200 overflow-hidden z-50")
      .style("top", "16px").style("right", "16px")

    function showEntityDetail(event, d) {
      const details = d.details || []
      const bens = details.filter(x => x.outcome === "benefits")
      const loses = details.filter(x => x.outcome === "loses")
      let html = `
        <div class="px-5 py-3 bg-gray-50 border-b flex items-center justify-between">
          <div><span class="font-bold text-gray-900 text-base">${d.name}</span> <span class="text-gray-400 text-xs ml-1">${d.type}</span></div>
          <button class="entity-detail-close text-gray-400 hover:text-gray-600 p-1"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg></button>
        </div>
        <div class="px-5 py-3 max-h-[500px] overflow-y-auto space-y-3">`
      if (bens.length) {
        html += `<h4 class="text-xs font-semibold text-green-700 uppercase tracking-wider">Benefits (${bens.length})</h4>`
        bens.forEach(b => {
          html += `<div class="pl-3 border-l-2 border-green-300 mb-2">
            <span class="text-xs text-blue-600 cursor-pointer underline section-link-inline" data-sec="${b.section_number}">\u00A7${b.section_number}</span>
            <p class="text-xs text-gray-600 mt-0.5">${(b.detail || '').slice(0, 200)}</p></div>`
        })
      }
      if (loses.length) {
        html += `<h4 class="text-xs font-semibold text-red-700 uppercase tracking-wider mt-2">Loses (${loses.length})</h4>`
        loses.forEach(b => {
          html += `<div class="pl-3 border-l-2 border-red-300 mb-2">
            <span class="text-xs text-blue-600 cursor-pointer underline section-link-inline" data-sec="${b.section_number}">\u00A7${b.section_number}</span>
            <p class="text-xs text-gray-600 mt-0.5">${(b.detail || '').slice(0, 200)}</p></div>`
        })
      }
      html += `</div>`
      detailDiv.html(html).classed("hidden", false)
      detailDiv.select(".entity-detail-close").on("click", () => detailDiv.classed("hidden", true))
      detailDiv.selectAll(".section-link-inline").on("click", function() {
        hook.pushEvent("preview_section", {sec: this.dataset.sec})
      })
    }

    // Loses bars (grow left from center)
    svg.selectAll(".bar-lose").data(data.filter(d => d.loses > 0)).join("rect")
      .attr("x", d => xCenter - xRight(d.loses)).attr("y", d => y(d.name))
      .attr("width", d => xRight(d.loses)).attr("height", y.bandwidth())
      .attr("fill", "#fca5a5").attr("rx", 4).attr("cursor", "pointer")
      .on("mouseover", showEntityTip).on("mousemove", showEntityTip).on("mouseout", hideTip)
      .on("click", showEntityDetail)

    // Benefits bars (grow right from center)
    svg.selectAll(".bar-benefit").data(data.filter(d => d.benefits > 0)).join("rect")
      .attr("x", xCenter).attr("y", d => y(d.name))
      .attr("width", d => xRight(d.benefits)).attr("height", y.bandwidth())
      .attr("fill", "#86efac").attr("rx", 4).attr("cursor", "pointer")
      .on("mouseover", showEntityTip).on("mousemove", showEntityTip).on("mouseout", hideTip)
      .on("click", showEntityDetail)

    // Count labels
    svg.selectAll(".count-lose").data(data.filter(d => d.loses > 0)).join("text")
      .attr("x", d => xCenter - xRight(d.loses) + 8).attr("y", d => y(d.name) + y.bandwidth() / 2)
      .attr("dy", "0.35em").attr("fill", "#991b1b").attr("font-size", "12px").attr("font-weight", "700").text(d => d.loses)
      .style("pointer-events", "none")
    svg.selectAll(".count-benefit").data(data.filter(d => d.benefits > 0)).join("text")
      .attr("x", d => xCenter + xRight(d.benefits) - 8).attr("y", d => y(d.name) + y.bandwidth() / 2)
      .attr("dy", "0.35em").attr("text-anchor", "end").attr("fill", "#166534").attr("font-size", "12px").attr("font-weight", "700").text(d => d.benefits)
      .style("pointer-events", "none")

    // Entity names (clickable)
    svg.selectAll(".label").data(data).join("text")
      .attr("x", margin.left - 12).attr("y", d => y(d.name) + y.bandwidth() / 2)
      .attr("dy", "0.35em").attr("text-anchor", "end").attr("fill", "#1e293b")
      .attr("font-size", "13px").attr("font-weight", d => Math.abs(d.net) >= 3 ? "700" : "500")
      .attr("cursor", "pointer")
      .text(d => d.name)
      .on("mouseover", function() { d3.select(this).attr("fill", "#2563eb").attr("text-decoration", "underline") })
      .on("mouseout", function(e, d) { d3.select(this).attr("fill", "#1e293b").attr("text-decoration", "none") })
      .on("click", showEntityDetail)

    // Type badges
    const typeColors = {
      "agency": "#3b82f6", "industry": "#f59e0b", "population_group": "#8b5cf6",
      "program": "#06b6d4", "state": "#10b981", "other": "#6b7280"
    }
    svg.selectAll(".type-badge").data(data).join("text")
      .attr("x", width - margin.right + 10).attr("y", d => y(d.name) + y.bandwidth() / 2)
      .attr("dy", "0.35em").attr("fill", d => typeColors[d.type] || "#94a3b8")
      .attr("font-size", "11px").attr("font-weight", "500")
      .text(d => d.type === "population_group" ? "population" : d.type)
  }
}

// Money flow chart — horizontal bars sorted by amount
export const MoneyChart = {
  mounted() {
    this.handleEvent("money_data", ({flows}) => {
      ensureD3().then(() => this.renderChart(flows))
    })
  },

  renderChart(flows) {
    const el = this.el
    el.innerHTML = ""

    if (!flows || flows.length === 0) {
      el.innerHTML = '<p class="text-gray-400 text-center py-8">No money flow data for this scope</p>'
      return
    }

    let data = flows
      .filter(f => f.amount_dollars && f.amount_dollars > 0)
      .sort((a, b) => b.amount_dollars - a.amount_dollars)
      .slice(0, 40)

    if (data.length === 0) {
      el.innerHTML = '<p class="text-gray-400 text-center py-8">No quantified money flows</p>'
      return
    }

    const width = el.clientWidth || 800
    const barHeight = 28
    const margin = {top: 40, right: 200, bottom: 20, left: 60}
    const height = margin.top + margin.bottom + data.length * barHeight

    const svg = d3.select(el).append("svg").attr("width", width).attr("height", height)

    const maxVal = d3.max(data, d => d.amount_dollars) || 1
    const x = d3.scaleLog().domain([1, maxVal]).range([margin.left, width - margin.right]).clamp(true)

    const y = d3.scaleBand().domain(data.map((_, i) => i))
      .range([margin.top, height - margin.bottom]).padding(0.2)

    const colorScale = d => {
      if (d.direction === "appropriation" || d.direction === "spending") return "#3b82f6"
      if (d.direction === "rescission" || d.direction === "cut") return "#ef4444"
      if (d.direction === "revenue" || d.direction === "tax") return "#16a34a"
      return "#8b5cf6"
    }

    // Tooltip div
    el.style.position = "relative"
    const tooltip = d3.select(el).append("div")
      .style("position", "absolute").style("pointer-events", "none")
      .style("opacity", 0).style("transition", "opacity 0.15s")
      .attr("class", "bg-gray-900 text-white text-xs rounded-lg shadow-xl p-4 max-w-xs z-50 leading-relaxed")

    function showTip(event, d) {
      const dir = d.direction || "unknown"
      const dirColor = (dir === "appropriation" || dir === "spending") ? "#93c5fd"
        : (dir === "rescission" || dir === "cut") ? "#fca5a5"
        : (dir === "revenue" || dir === "tax") ? "#86efac" : "#c4b5fd"
      tooltip.html(`
        <div class="font-semibold text-blue-300 text-sm mb-1">\u00A7${d.section_number}</div>
        <div class="text-gray-400 mb-2">${d.title_name || ""}</div>
        <div class="font-mono font-bold text-base mb-1">${d.amount_text || formatDollars(d.amount_dollars)}</div>
        <span class="inline-block px-2 py-0.5 rounded text-xs font-medium mb-2" style="background:${dirColor}30;color:${dirColor}">${dir}</span>
        ${d.notes ? `<div class="text-gray-300 mt-1">${d.notes.slice(0, 250)}</div>` : ""}
        ${d.source_law ? `<div class="text-gray-500 mt-1 text-[10px]">Source: ${d.source_law}</div>` : ""}
        <div class="text-blue-400 mt-2">Click to view section \u2192</div>
      `)
      const rect = el.getBoundingClientRect()
      tooltip.style("left", (event.clientX - rect.left + 12) + "px")
        .style("top", (event.clientY - rect.top - 10) + "px")
        .style("opacity", 1)
    }
    function hideTip() { tooltip.style("opacity", 0) }
    function clickSection(event, d) {
      window.location.href = "/section/" + d.section_number
    }

    svg.selectAll(".bar").data(data).join("rect")
      .attr("x", margin.left).attr("y", (d, i) => y(i))
      .attr("width", d => Math.max(2, x(d.amount_dollars) - margin.left))
      .attr("height", y.bandwidth()).attr("fill", colorScale).attr("opacity", 0.8).attr("rx", 3)
      .attr("cursor", "pointer")
      .on("mouseover", showTip).on("mousemove", showTip).on("mouseout", hideTip)
      .on("click", clickSection)

    svg.selectAll(".sec-label").data(data).join("text")
      .attr("x", margin.left - 6).attr("y", (d, i) => y(i) + y.bandwidth() / 2)
      .attr("dy", "0.35em").attr("text-anchor", "end").attr("fill", "#475569").attr("font-size", "10px")
      .attr("cursor", "pointer")
      .text(d => "\u00A7" + d.section_number)
      .on("mouseover", showTip).on("mousemove", showTip).on("mouseout", hideTip)
      .on("click", clickSection)

    svg.selectAll(".amount-label").data(data).join("text")
      .attr("x", d => Math.max(margin.left + 4, x(d.amount_dollars) + 6))
      .attr("y", (d, i) => y(i) + y.bandwidth() / 2)
      .attr("dy", "0.35em").attr("fill", "#1e293b").attr("font-size", "11px")
      .attr("cursor", "pointer")
      .text(d => {
        const amt = formatDollars(d.amount_dollars)
        const note = d.notes ? " \u2014 " + d.notes.slice(0, 50) : ""
        return amt + note
      })
      .on("mouseover", showTip).on("mousemove", showTip).on("mouseout", hideTip)
      .on("click", clickSection)

    // Legend
    const legend = svg.append("g").attr("transform", `translate(${margin.left}, 8)`)
    const types = [
      {label: "Spending", color: "#3b82f6"}, {label: "Cut/Rescission", color: "#ef4444"},
      {label: "Revenue", color: "#16a34a"}, {label: "Other", color: "#8b5cf6"}
    ]
    types.forEach((t, i) => {
      legend.append("rect").attr("x", i * 130).attr("y", 0).attr("width", 12).attr("height", 12).attr("fill", t.color).attr("rx", 2)
      legend.append("text").attr("x", i * 130 + 16).attr("y", 10).attr("fill", "#64748b").attr("font-size", "11px").text(t.label)
    })
  }
}

function formatDollars(n) {
  if (n >= 1e12) return "$" + (n / 1e12).toFixed(1) + "T"
  if (n >= 1e9) return "$" + (n / 1e9).toFixed(1) + "B"
  if (n >= 1e6) return "$" + (n / 1e6).toFixed(0) + "M"
  if (n >= 1e3) return "$" + (n / 1e3).toFixed(0) + "K"
  return "$" + n.toFixed(0)
}

// Network graph — force-directed, rendered inside a modal
export const EntityNetwork = {
  mounted() {
    this.handleEvent("network_data", ({entities}) => {
      this._entities = entities
      ensureD3().then(() => {
        // Only render if modal is visible (has dimensions)
        if (this.el.clientWidth > 0) this.renderNetwork(entities)
      })
    })
    // Re-render when modal opens (element becomes visible)
    this._observer = new MutationObserver(() => {
      if (this.el.clientWidth > 0 && this._entities) {
        ensureD3().then(() => this.renderNetwork(this._entities))
        this._observer.disconnect()
      }
    })
    this._observer.observe(this.el.closest("[data-modal]") || this.el.parentElement, {attributes: true, attributeFilter: ["class", "style"]})
  },

  destroyed() {
    if (this._observer) this._observer.disconnect()
  },

  renderNetwork(entities) {
    const el = this.el
    const hook = this
    if (el.querySelector("svg")) return // Already rendered
    el.innerHTML = ""

    if (!entities || entities.length === 0) {
      el.innerHTML = '<p class="text-gray-400 text-center py-8">No data for network view</p>'
      return
    }

    const entityMap = {}
    const sectionSet = new Set()
    const sectionDetails = {} // section_number -> [{entity, outcome, detail}]
    const links = []

    entities.forEach(e => {
      if (!entityMap[e.entity_name]) {
        entityMap[e.entity_name] = {id: e.entity_name, type: "entity", entity_type: e.entity_type, benefits: 0, loses: 0}
      }
      if (e.outcome === "benefits") entityMap[e.entity_name].benefits++
      else entityMap[e.entity_name].loses++
      const secId = "\u00A7" + e.section_number
      sectionSet.add(secId)
      if (!sectionDetails[secId]) sectionDetails[secId] = []
      sectionDetails[secId].push({entity: e.entity_name, outcome: e.outcome, detail: e.detail, type: e.entity_type, title_name: e.title_name})
      links.push({source: e.entity_name, target: secId, outcome: e.outcome})
    })

    const significantEntities = Object.values(entityMap).filter(e => e.benefits + e.loses >= 2)
    const sigNames = new Set(significantEntities.map(e => e.id))
    const filteredLinks = links.filter(l => sigNames.has(l.source))
    const usedSections = new Set(filteredLinks.map(l => l.target))

    const nodes = [
      ...significantEntities,
      ...[...usedSections].map(s => ({id: s, type: "section"}))
    ]

    if (nodes.length === 0) {
      el.innerHTML = '<p class="text-gray-400 text-center py-8">Not enough connections</p>'
      return
    }

    const width = el.clientWidth || 900
    const height = el.clientHeight || 600

    const svg = d3.select(el).append("svg")
      .attr("width", width).attr("height", height)
      .attr("viewBox", [0, 0, width, height])

    const g = svg.append("g")
    svg.call(d3.zoom().scaleExtent([0.3, 4]).on("zoom", (event) => g.attr("transform", event.transform)))

    const simulation = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(filteredLinks).id(d => d.id).distance(80))
      .force("charge", d3.forceManyBody().strength(-200))
      .force("center", d3.forceCenter(width / 2, height / 2))
      .force("collision", d3.forceCollide().radius(20))

    const link = g.append("g").selectAll("line").data(filteredLinks).join("line")
      .attr("stroke", d => d.outcome === "benefits" ? "#86efac" : "#fca5a5")
      .attr("stroke-opacity", 0.6).attr("stroke-width", 1.5)

    const node = g.append("g").selectAll("g").data(nodes).join("g")
      .call(d3.drag()
        .on("start", (event, d) => { if (!event.active) simulation.alphaTarget(0.3).restart(); d.fx = d.x; d.fy = d.y })
        .on("drag", (event, d) => { d.fx = event.x; d.fy = event.y })
        .on("end", (event, d) => { if (!event.active) simulation.alphaTarget(0); d.fx = null; d.fy = null })
      )

    node.filter(d => d.type === "entity").append("circle")
      .attr("r", d => 6 + Math.sqrt(d.benefits + d.loses) * 3)
      .attr("fill", d => d.benefits > d.loses ? "#22c55e" : d.loses > d.benefits ? "#ef4444" : "#a855f7")
      .attr("stroke", "#fff").attr("stroke-width", 1.5).attr("opacity", 0.85)

    node.filter(d => d.type === "section").append("rect")
      .attr("x", -10).attr("y", -10).attr("width", 20).attr("height", 20).attr("rx", 4)
      .attr("fill", "#e2e8f0").attr("stroke", "#94a3b8").attr("stroke-width", 1.5)
      .attr("cursor", "pointer")

    node.append("text")
      .attr("dx", d => d.type === "entity" ? 10 : 14).attr("dy", "0.35em")
      .attr("font-size", d => d.type === "entity" ? "11px" : "10px")
      .attr("fill", d => d.type === "entity" ? "#1e293b" : "#475569")
      .attr("font-weight", d => {
        if (d.type === "section") return "600"
        return (d.benefits + d.loses >= 4) ? "600" : "400"
      })
      .attr("cursor", d => d.type === "section" ? "pointer" : "default")
      .text(d => d.id.length > 25 ? d.id.slice(0, 23) + "\u2026" : d.id)

    // Section click → show detail panel inside the graph
    const detailPanel = d3.select(el).append("div")
      .attr("class", "absolute top-4 right-4 w-96 max-h-[80%] bg-white rounded-xl shadow-2xl border border-gray-200 overflow-hidden z-50 hidden")
      .style("position", "absolute")
    el.style.position = "relative"

    node.filter(d => d.type === "section").on("click", (event, d) => {
      event.stopPropagation()
      const secNum = d.id.replace("\u00A7", "")
      const details = sectionDetails[d.id] || []
      const benefits = details.filter(x => x.outcome === "benefits")
      const loses = details.filter(x => x.outcome === "loses")

      let html = `
        <div class="px-5 py-4 bg-gray-50 border-b border-gray-200 flex items-center justify-between">
          <div>
            <h3 class="text-base font-bold text-gray-900">\u00A7${secNum}</h3>
            <p class="text-xs text-gray-500 mt-0.5">${details[0]?.title_name || ""}</p>
          </div>
          <div class="flex gap-2">
            <button class="detail-view-section text-xs px-3 py-1.5 rounded-lg bg-blue-600 text-white hover:bg-blue-700 cursor-pointer" data-sec="${secNum}">View Full Section</button>
            <button class="detail-close text-gray-400 hover:text-gray-600 p-1"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg></button>
          </div>
        </div>
        <div class="px-5 py-3 max-h-[400px] overflow-y-auto space-y-3">`

      if (benefits.length > 0) {
        html += `<div><h4 class="text-xs font-semibold text-green-700 uppercase tracking-wider mb-2">Benefits (${benefits.length})</h4>`
        benefits.forEach(b => {
          html += `<div class="mb-2 pl-3 border-l-2 border-green-300">
            <span class="text-sm font-medium text-gray-900">${b.entity}</span>
            <span class="ml-1 text-xs text-gray-400">${b.type}</span>
            <p class="text-xs text-gray-600 mt-0.5 leading-relaxed">${(b.detail || "").slice(0, 200)}</p>
          </div>`
        })
        html += `</div>`
      }

      if (loses.length > 0) {
        html += `<div><h4 class="text-xs font-semibold text-red-700 uppercase tracking-wider mb-2">Loses (${loses.length})</h4>`
        loses.forEach(b => {
          html += `<div class="mb-2 pl-3 border-l-2 border-red-300">
            <span class="text-sm font-medium text-gray-900">${b.entity}</span>
            <span class="ml-1 text-xs text-gray-400">${b.type}</span>
            <p class="text-xs text-gray-600 mt-0.5 leading-relaxed">${(b.detail || "").slice(0, 200)}</p>
          </div>`
        })
        html += `</div>`
      }

      html += `</div>`
      detailPanel.html(html).classed("hidden", false)
      detailPanel.select(".detail-close").on("click", () => detailPanel.classed("hidden", true))
      detailPanel.select(".detail-view-section").on("click", (event) => {
        event.stopPropagation()
        hook.pushEvent("preview_section", {sec: secNum})
      })
    })

    // Click on background closes panel
    svg.on("click", () => detailPanel.classed("hidden", true))

    simulation.on("tick", () => {
      link.attr("x1", d => d.source.x).attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x).attr("y2", d => d.target.y)
      node.attr("transform", d => `translate(${d.x},${d.y})`)
    })
  }
}
