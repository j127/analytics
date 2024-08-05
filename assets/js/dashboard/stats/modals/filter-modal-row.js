import React, { useMemo } from "react"

import FilterOperatorSelector from "../../components/filter-operator-selector"
import Combobox from '../../components/combobox'

import { FILTER_OPERATIONS, fetchSuggestions, isFreeChoiceFilter, getLabel, formattedFilters } from "../../util/filters"
import { apiPath } from '../../util/url'
import { useQueryContext } from "../../query-context"
import { useSiteContext } from "../../site-context"

export default function FilterModalRow({
  filter,
  labels,
  onUpdate
}) {
  const { query } = useQueryContext();
  const site = useSiteContext();
  const [operation, filterKey, clauses] = filter

  const selectedClauses = useMemo(
    () => clauses.map((value) => ({ value, label: getLabel(labels, filterKey, value) })),
    [filter, labels]
  )

  function onComboboxSelect(selection) {
    const newClauses = selection.map(({ value }) => value)
    const newLabels = Object.fromEntries(selection.map(({ label, value }) => [value, label]))

    onUpdate(
      [operation, filterKey, newClauses],
      newLabels
    )
  }

  function fetchOptions(input) {
    if ([FILTER_OPERATIONS.contains, FILTER_OPERATIONS.does_not_contain].includes(operation)) {
      return Promise.resolve([])
    }

    let additionalFilter = null

    if (filterKey !== 'goal') { additionalFilter = [FILTER_OPERATIONS.isNot, filterKey, clauses] }

    return fetchSuggestions(apiPath(site, `/suggestions/${filterKey}`), query, input, additionalFilter)
  }

  return (
    <div className="grid grid-cols-11 mt-1">
      <div className="col-span-3">
        <FilterOperatorSelector
          forFilter={filterKey}
          onSelect={(newOperation) => onUpdate([newOperation, filterKey, clauses], labels)}
          selectedType={operation}
        />
      </div>
      <div className="col-span-8 ml-2">
        <Combobox
          fetchOptions={fetchOptions}
          freeChoice={isFreeChoiceFilter(filterKey)}
          values={selectedClauses}
          onSelect={onComboboxSelect}
          placeholder={`Select ${withIndefiniteArticle(formattedFilters[filterKey])}`}
        />
      </div>
    </div>
  )
}

function withIndefiniteArticle(word) {
  if (word.startsWith('UTM')) {
    return `a ${word}`
  } if (['a', 'e', 'i', 'o', 'u'].some((vowel) => word.toLowerCase().startsWith(vowel))) {
    return `an ${word}`
  }
  return `a ${word}`
}
