import React, { useState } from 'react';

import Historical from './historical'
import Realtime from './realtime'
import { useIsRealtimeDashboard } from './util/filters'

export const statsBoxClass = "stats-item relative w-full mt-6 p-4 flex flex-col bg-white dark:bg-gray-825 shadow-xl rounded"

function Dashboard() {
  const isRealTimeDashboard = useIsRealtimeDashboard();
  const [importedDataInView, setImportedDataInView] = useState(false)

  if (isRealTimeDashboard) {
    return (
      <Realtime />
    )
  } else {
    return (
      <Historical
        importedDataInView={importedDataInView}
        updateImportedDataInView={setImportedDataInView}
      />
    )
  }
}

export default Dashboard
