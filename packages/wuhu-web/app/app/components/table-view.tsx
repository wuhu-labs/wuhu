import type { QueryOutput } from '~/lib/contract.gen'

export function TableView({ output }: { output: QueryOutput }) {
  const count = output.rows.length
  return (
    <div className='wuhu-table'>
      <table>
        <thead>
          <tr>
            {output.columns.map((column) => <th key={column}>{column}</th>)}
          </tr>
        </thead>
        <tbody>
          {output.rows.map((row, index) => (
            <tr key={index}>
              {row.map((cell, cellIndex) => (
                <td key={cellIndex} data-type={cellType(cell)}>
                  {renderCell(cell)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <p className='wuhu-table-foot'>
        {count === 0 ? 'No rows' : `${count} ${count === 1 ? 'row' : 'rows'}`}
      </p>
    </div>
  )
}

function cellType(cell: unknown): string {
  if (cell === null || cell === undefined) return 'null'
  if (typeof cell === 'object') return 'json'
  return typeof cell
}

function renderCell(cell: unknown): string {
  if (cell === null || cell === undefined) return ''
  if (typeof cell === 'string') return cell
  return JSON.stringify(cell)
}
