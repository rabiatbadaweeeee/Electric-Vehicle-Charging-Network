;; Electric Vehicle Charging Station Management Contract
;; Handles station registration, availability tracking, and reservation system

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-STATION-NOT-FOUND (err u101))
(define-constant ERR-STATION-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-CAPACITY (err u103))
(define-constant ERR-STATION-OFFLINE (err u104))
(define-constant ERR-RESERVATION-CONFLICT (err u105))
(define-constant ERR-INVALID-TIME (err u106))
(define-constant ERR-RESERVATION-NOT-FOUND (err u107))
(define-constant ERR-NOT-RESERVATION-OWNER (err u108))
(define-constant ERR-INVALID-DURATION (err u109))

;; Data Variables
(define-data-var next-station-id uint u1)
(define-data-var next-reservation-id uint u1)

;; Station status enumeration
(define-constant STATUS-ONLINE u1)
(define-constant STATUS-OFFLINE u2)
(define-constant STATUS-MAINTENANCE u3)

;; Charging type enumeration
(define-constant TYPE-SLOW u1)
(define-constant TYPE-FAST u2)
(define-constant TYPE-ULTRA-FAST u3)

;; Data Maps
(define-map stations
  { station-id: (string-ascii 50) }
  {
    owner: principal,
    location: { lat: int, lng: int },
    capacity: uint,
    charging-type: uint,
    status: uint,
    price-per-kwh: uint,
    total-sessions: uint,
    total-energy-delivered: uint,
    created-at: uint,
    last-maintenance: uint
  }
)

(define-map station-availability
  { station-id: (string-ascii 50) }
  {
    available-slots: uint,
    total-slots: uint,
    current-load: uint,
    last-updated: uint
  }
)

(define-map reservations
  { reservation-id: uint }
  {
    station-id: (string-ascii 50),
    user: principal,
    start-time: uint,
    duration: uint,
    status: uint,
    created-at: uint
  }
)

(define-map user-reservations
  { user: principal, station-id: (string-ascii 50) }
  { reservation-id: uint }
)

;; Station operators (authorized to manage stations)
(define-map station-operators
  { operator: principal }
  { authorized: bool }
)

;; Reservation status enumeration
(define-constant RESERVATION-ACTIVE u1)
(define-constant RESERVATION-COMPLETED u2)
(define-constant RESERVATION-CANCELLED u3)

;; Authorization Functions
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

(define-private (is-station-operator)
  (default-to false (get authorized (map-get? station-operators { operator: tx-sender })))
)

(define-private (is-authorized)
  (or (is-contract-owner) (is-station-operator))
)

;; Station Management Functions
(define-public (authorize-operator (operator principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (map-set station-operators { operator: operator } { authorized: true }))
  )
)

(define-public (revoke-operator (operator principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (map-set station-operators { operator: operator } { authorized: false }))
  )
)

(define-public (register-station
  (station-id (string-ascii 50))
  (location { lat: int, lng: int })
  (capacity uint)
  (charging-type uint)
  (price-per-kwh uint)
  (total-slots uint))
  (begin
    (asserts! (is-authorized) ERR-NOT-AUTHORIZED)
    (asserts! (> capacity u0) ERR-INVALID-CAPACITY)
    (asserts! (is-none (map-get? stations { station-id: station-id })) ERR-STATION-ALREADY-EXISTS)
    (asserts! (and (>= charging-type TYPE-SLOW) (<= charging-type TYPE-ULTRA-FAST)) ERR-INVALID-CAPACITY)

    (map-set stations
      { station-id: station-id }
      {
        owner: tx-sender,
        location: location,
        capacity: capacity,
        charging-type: charging-type,
        status: STATUS-ONLINE,
        price-per-kwh: price-per-kwh,
        total-sessions: u0,
        total-energy-delivered: u0,
        created-at: block-height,
        last-maintenance: block-height
      }
    )

    (map-set station-availability
      { station-id: station-id }
      {
        available-slots: total-slots,
        total-slots: total-slots,
        current-load: u0,
        last-updated: block-height
      }
    )

    (ok station-id)
  )
)

(define-public (update-station-status (station-id (string-ascii 50)) (new-status uint))
  (let ((station (unwrap! (map-get? stations { station-id: station-id }) ERR-STATION-NOT-FOUND)))
    (asserts! (is-authorized) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= new-status STATUS-ONLINE) (<= new-status STATUS-MAINTENANCE)) ERR-INVALID-CAPACITY)

    (ok (map-set stations
      { station-id: station-id }
      (merge station { status: new-status })
    ))
  )
)

(define-public (update-availability
  (station-id (string-ascii 50))
  (available-slots uint)
  (current-load uint))
  (let ((availability (unwrap! (map-get? station-availability { station-id: station-id }) ERR-STATION-NOT-FOUND)))
    (asserts! (is-authorized) ERR-NOT-AUTHORIZED)
    (asserts! (<= available-slots (get total-slots availability)) ERR-INVALID-CAPACITY)

    (ok (map-set station-availability
      { station-id: station-id }
      (merge availability {
        available-slots: available-slots,
        current-load: current-load,
        last-updated: block-height
      })
    ))
  )
)

;; Reservation Functions
(define-public (make-reservation
  (station-id (string-ascii 50))
  (start-time uint)
  (duration uint))
  (let (
    (station (unwrap! (map-get? stations { station-id: station-id }) ERR-STATION-NOT-FOUND))
    (availability (unwrap! (map-get? station-availability { station-id: station-id }) ERR-STATION-NOT-FOUND))
    (reservation-id (var-get next-reservation-id))
  )
    (asserts! (is-eq (get status station) STATUS-ONLINE) ERR-STATION-OFFLINE)
    (asserts! (> (get available-slots availability) u0) ERR-RESERVATION-CONFLICT)
    (asserts! (> start-time block-height) ERR-INVALID-TIME)
    (asserts! (and (> duration u0) (< duration u86400)) ERR-INVALID-DURATION) ;; Max 24 hours

    ;; Check for existing reservation conflicts
    (asserts! (is-none (map-get? user-reservations { user: tx-sender, station-id: station-id })) ERR-RESERVATION-CONFLICT)

    ;; Create reservation
    (map-set reservations
      { reservation-id: reservation-id }
      {
        station-id: station-id,
        user: tx-sender,
        start-time: start-time,
        duration: duration,
        status: RESERVATION-ACTIVE,
        created-at: block-height
      }
    )

    ;; Track user reservation
    (map-set user-reservations
      { user: tx-sender, station-id: station-id }
      { reservation-id: reservation-id }
    )

    ;; Update availability
    (map-set station-availability
      { station-id: station-id }
      (merge availability {
        available-slots: (- (get available-slots availability) u1),
        last-updated: block-height
      })
    )

    ;; Increment reservation ID
    (var-set next-reservation-id (+ reservation-id u1))

    (ok reservation-id)
  )
)

(define-public (cancel-reservation (reservation-id uint))
  (let ((reservation (unwrap! (map-get? reservations { reservation-id: reservation-id }) ERR-RESERVATION-NOT-FOUND)))
    (asserts! (is-eq (get user reservation) tx-sender) ERR-NOT-RESERVATION-OWNER)
    (asserts! (is-eq (get status reservation) RESERVATION-ACTIVE) ERR-RESERVATION-NOT-FOUND)

    (let (
      (station-id (get station-id reservation))
      (availability (unwrap! (map-get? station-availability { station-id: station-id }) ERR-STATION-NOT-FOUND))
    )
      ;; Update reservation status
      (map-set reservations
        { reservation-id: reservation-id }
        (merge reservation { status: RESERVATION-CANCELLED })
      )

      ;; Remove user reservation tracking
      (map-delete user-reservations { user: tx-sender, station-id: station-id })

      ;; Update availability
      (map-set station-availability
        { station-id: station-id }
        (merge availability {
          available-slots: (+ (get available-slots availability) u1),
          last-updated: block-height
        })
      )

      (ok true)
    )
  )
)

(define-public (complete-reservation (reservation-id uint) (energy-delivered uint))
  (let ((reservation (unwrap! (map-get? reservations { reservation-id: reservation-id }) ERR-RESERVATION-NOT-FOUND)))
    (asserts! (is-authorized) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status reservation) RESERVATION-ACTIVE) ERR-RESERVATION-NOT-FOUND)

    (let (
      (station-id (get station-id reservation))
      (station (unwrap! (map-get? stations { station-id: station-id }) ERR-STATION-NOT-FOUND))
      (availability (unwrap! (map-get? station-availability { station-id: station-id }) ERR-STATION-NOT-FOUND))
    )
      ;; Update reservation status
      (map-set reservations
        { reservation-id: reservation-id }
        (merge reservation { status: RESERVATION-COMPLETED })
      )

      ;; Update station statistics
      (map-set stations
        { station-id: station-id }
        (merge station {
          total-sessions: (+ (get total-sessions station) u1),
          total-energy-delivered: (+ (get total-energy-delivered station) energy-delivered)
        })
      )

      ;; Update availability
      (map-set station-availability
        { station-id: station-id }
        (merge availability {
          available-slots: (+ (get available-slots availability) u1),
          last-updated: block-height
        })
      )

      ;; Remove user reservation tracking
      (map-delete user-reservations { user: (get user reservation), station-id: station-id })

      (ok true)
    )
  )
)

;; Read-only Functions
(define-read-only (get-station (station-id (string-ascii 50)))
  (map-get? stations { station-id: station-id })
)

(define-read-only (get-station-availability (station-id (string-ascii 50)))
  (map-get? station-availability { station-id: station-id })
)

(define-read-only (get-reservation (reservation-id uint))
  (map-get? reservations { reservation-id: reservation-id })
)

(define-read-only (get-user-reservation (user principal) (station-id (string-ascii 50)))
  (map-get? user-reservations { user: user, station-id: station-id })
)

(define-read-only (is-station-available (station-id (string-ascii 50)))
  (match (map-get? station-availability { station-id: station-id })
    availability (> (get available-slots availability) u0)
    false
  )
)

(define-read-only (get-station-utilization (station-id (string-ascii 50)))
  (match (map-get? station-availability { station-id: station-id })
    availability
      (let ((total (get total-slots availability))
            (available (get available-slots availability)))
        (if (> total u0)
          (some (/ (* (- total available) u100) total))
          none
        )
      )
    none
  )
)

(define-read-only (is-operator (operator principal))
  (default-to false (get authorized (map-get? station-operators { operator: operator })))
)
