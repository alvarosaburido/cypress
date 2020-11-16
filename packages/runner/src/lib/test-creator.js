import { $ } from '@packages/driver'
import eventManager from '../lib/event-manager'

const eventTypes = [
  'click',
  'dblclick',
  'change',
  'keydown',
  'select',
  'submit',
]

const eventsWithValue = [
  'change',
  'keydown',
  'select',
]

class TestCreator {
  startCreating = (body) => {
    this._body = body
    this._log = []

    eventTypes.forEach((event) => {
      this._body.addEventListener(event, this._recordEvent, {
        capture: true,
        passive: true,
      })
    })
  }

  stopCreating = () => {
    eventTypes.forEach((event) => {
      this._body.removeEventListener(event, this._recordEvent, {
        capture: true,
      })
    })
  }

  resetLog = () => {
    this._log = []
  }

  _getCommand = (event, $el) => {
    const tagName = $el.prop('tagName')
    const { type } = event

    if (tagName === 'SELECT' && event.type === 'change') {
      return 'select'
    }

    if (event.type === 'keydown') {
      return 'type'
    }

    return type
  }

  _getValue = (event, $el) => {
    if (!eventsWithValue.includes(event.type)) {
      return null
    }

    if (event.type === 'keydown') {
      return event.key
    }

    return $el.val()
  }

  _recordEvent = (event) => {
    // only capture events sent by the actual user
    if (!event.isTrusted) {
      return
    }

    const $el = $(event.target)

    const Cypress = eventManager.getCypress()

    const selector = Cypress.SelectorPlayground.getSelector($el)

    const action = ({
      selector,
      command: this._getCommand(event, $el),
      value: this._getValue(event, $el),
    })

    this._log.push(action)

    this._filterLog()

    this._emitUpdatedLog()
  }

  _filterLog = () => {
    const { length } = this._log

    const lastAction = this._log[length - 1]

    if (lastAction.command === 'change') {
      this._log.splice(length - 1)

      return
    }

    if (length > 1) {
      const secondLast = this._log[length - 2]

      if (lastAction.selector === secondLast.selector) {
        if (lastAction.command === 'type' && secondLast.command === 'type') {
          secondLast.value += lastAction.value
          this._log.splice(length - 1)

          return
        }

        if (lastAction.command === 'dblclick' && secondLast.command === 'click' && length > 2) {
          const thirdLast = this._log[length - 3]

          if (lastAction.selector === thirdLast.selector && thirdLast.command === 'click') {
            this._log.splice(length - 3, 2)
          }
        }
      }
    }
  }

  _emitUpdatedLog = () => {
    eventManager.emit('update:creating:test:log', this._log)
  }
}

export default new TestCreator()
