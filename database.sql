-- ============================================================
-- SMART HOSPITAL MANAGEMENT SYSTEM — Complete Database Script
-- Run in psql or pgAdmin in this exact order
-- ============================================================

DROP TABLE IF EXISTS payments CASCADE;
DROP TABLE IF EXISTS bills CASCADE;
DROP TABLE IF EXISTS prescriptions CASCADE;
DROP TABLE IF EXISTS medicines CASCADE;
DROP TABLE IF EXISTS treatments CASCADE;
DROP TABLE IF EXISTS appointments CASCADE;
DROP TABLE IF EXISTS doctors CASCADE;
DROP TABLE IF EXISTS patients CASCADE;
DROP TABLE IF EXISTS departments CASCADE;
DROP VIEW IF EXISTS v_revenue_analytics CASCADE;
DROP VIEW IF EXISTS v_appointment_summary CASCADE;
DROP VIEW IF EXISTS v_patient_medical_history CASCADE;
DROP VIEW IF EXISTS v_doctor_schedule CASCADE;
DROP FUNCTION IF EXISTS update_bill_status() CASCADE;
DROP FUNCTION IF EXISTS prevent_past_appointment() CASCADE;
DROP FUNCTION IF EXISTS reduce_medicine_stock() CASCADE;
DROP FUNCTION IF EXISTS restock_medicine(INTEGER, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS get_department_stats() CASCADE;
DROP FUNCTION IF EXISTS generate_bill(INTEGER) CASCADE;

-- ============================================================
-- SCHEMA (3NF Normalized)
-- Relationships:
--   1:1  Department ↔ Head Doctor
--   1:1  Appointment ↔ Treatment
--   1:1  Appointment ↔ Bill
--   1:N  Department → Doctors
--   1:N  Patient → Appointments
--   1:N  Doctor → Appointments
--   1:N  Treatment → Prescriptions
--   1:N  Medicine → Prescriptions
--   1:N  Patient → Bills
--   1:N  Bill → Payments
--   M:N  Treatment ↔ Medicine (via Prescriptions)
-- ============================================================

CREATE TABLE departments (
    dept_id        SERIAL PRIMARY KEY,
    name           VARCHAR(100) NOT NULL UNIQUE,
    description    TEXT,
    head_doctor_id INTEGER,
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE patients (
    patient_id  SERIAL PRIMARY KEY,
    name        VARCHAR(150) NOT NULL,
    dob         DATE,
    gender      VARCHAR(10) CHECK (gender IN ('Male','Female','Other')),
    phone       VARCHAR(15) NOT NULL,
    email       VARCHAR(150) UNIQUE,
    address     TEXT,
    blood_group VARCHAR(5) CHECK (blood_group IN ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE doctors (
    doctor_id        SERIAL PRIMARY KEY,
    name             VARCHAR(150) NOT NULL,
    specialization   VARCHAR(100) NOT NULL,
    phone            VARCHAR(15) NOT NULL,
    email            VARCHAR(150) UNIQUE,
    dept_id          INTEGER NOT NULL REFERENCES departments(dept_id) ON DELETE RESTRICT,
    experience_years INTEGER CHECK (experience_years >= 0),
    fee              DECIMAL(10,2) NOT NULL CHECK (fee >= 0),
    available_days   VARCHAR(50),
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- One-to-One: a doctor heads at most one department
ALTER TABLE departments ADD CONSTRAINT fk_dept_head
    FOREIGN KEY (head_doctor_id) REFERENCES doctors(doctor_id) ON DELETE SET NULL;
ALTER TABLE departments ADD CONSTRAINT uq_head_doctor UNIQUE (head_doctor_id);

CREATE TABLE appointments (
    appointment_id   SERIAL PRIMARY KEY,
    patient_id       INTEGER NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    doctor_id        INTEGER NOT NULL REFERENCES doctors(doctor_id) ON DELETE RESTRICT,
    appointment_date DATE NOT NULL,
    appointment_time TIME NOT NULL,
    status           VARCHAR(20) NOT NULL DEFAULT 'Scheduled'
                     CHECK (status IN ('Scheduled','Completed','Cancelled','No-Show')),
    reason           TEXT,
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_slot UNIQUE (doctor_id, appointment_date, appointment_time)
);

-- One-to-One: each appointment has at most one treatment
CREATE TABLE treatments (
    treatment_id      SERIAL PRIMARY KEY,
    appointment_id    INTEGER NOT NULL UNIQUE REFERENCES appointments(appointment_id) ON DELETE CASCADE,
    patient_id        INTEGER NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    doctor_id         INTEGER NOT NULL REFERENCES doctors(doctor_id) ON DELETE RESTRICT,
    diagnosis         TEXT NOT NULL,
    treatment_details TEXT,
    treatment_date    DATE NOT NULL,
    notes             TEXT,
    created_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE medicines (
    medicine_id    SERIAL PRIMARY KEY,
    name           VARCHAR(200) NOT NULL,
    category       VARCHAR(100),
    dosage_form    VARCHAR(50) CHECK (dosage_form IN ('Tablet','Capsule','Syrup','Injection','Cream','Drops','Inhaler','Powder')),
    unit_price     DECIMAL(10,2) NOT NULL CHECK (unit_price >= 0),
    stock_quantity INTEGER NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
    reorder_level  INTEGER NOT NULL DEFAULT 10 CHECK (reorder_level >= 0),
    manufacturer   VARCHAR(150),
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Many-to-Many junction table: treatments ↔ medicines
CREATE TABLE prescriptions (
    prescription_id SERIAL PRIMARY KEY,
    treatment_id    INTEGER NOT NULL REFERENCES treatments(treatment_id) ON DELETE CASCADE,
    medicine_id     INTEGER NOT NULL REFERENCES medicines(medicine_id) ON DELETE RESTRICT,
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    dosage          VARCHAR(100) NOT NULL,
    duration_days   INTEGER NOT NULL CHECK (duration_days > 0),
    instructions    TEXT,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_presc UNIQUE (treatment_id, medicine_id)
);

-- One-to-One: each appointment generates at most one bill
CREATE TABLE bills (
    bill_id          SERIAL PRIMARY KEY,
    patient_id       INTEGER NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    appointment_id   INTEGER NOT NULL UNIQUE REFERENCES appointments(appointment_id) ON DELETE CASCADE,
    consultation_fee DECIMAL(10,2) NOT NULL DEFAULT 0 CHECK (consultation_fee >= 0),
    medicine_cost    DECIMAL(10,2) NOT NULL DEFAULT 0 CHECK (medicine_cost >= 0),
    total_amount     DECIMAL(10,2) NOT NULL CHECK (total_amount >= 0),
    bill_date        DATE NOT NULL DEFAULT CURRENT_DATE,
    status           VARCHAR(20) NOT NULL DEFAULT 'Pending'
                      CHECK (status IN ('Pending','Paid','Partial','Overdue')),
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- One-to-Many: one bill can have multiple partial payments
CREATE TABLE payments (
    payment_id      SERIAL PRIMARY KEY,
    bill_id         INTEGER NOT NULL REFERENCES bills(bill_id) ON DELETE CASCADE,
    amount          DECIMAL(10,2) NOT NULL CHECK (amount > 0),
    payment_method  VARCHAR(30) NOT NULL CHECK (payment_method IN ('Cash','Card','UPI','Bank Transfer','Insurance')),
    payment_date    DATE NOT NULL DEFAULT CURRENT_DATE,
    reference_number VARCHAR(100),
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Performance indexes
CREATE INDEX idx_patients_name ON patients(name);
CREATE INDEX idx_doctors_dept ON doctors(dept_id);
CREATE INDEX idx_appt_patient ON appointments(patient_id);
CREATE INDEX idx_appt_doctor ON appointments(doctor_id);
CREATE INDEX idx_appt_date ON appointments(appointment_date);
CREATE INDEX idx_appt_status ON appointments(status);
CREATE INDEX idx_treat_patient ON treatments(patient_id);
CREATE INDEX idx_presc_treat ON prescriptions(treatment_id);
CREATE INDEX idx_presc_med ON prescriptions(medicine_id);
CREATE INDEX idx_bill_patient ON bills(patient_id);
CREATE INDEX idx_pay_bill ON payments(bill_id);

-- ============================================================
-- TRIGGERS
-- ============================================================

-- TRIGGER 1: Auto-reduce medicine stock when a prescription is created
CREATE OR REPLACE FUNCTION reduce_medicine_stock()
RETURNS TRIGGER AS $$ BEGIN
    UPDATE medicines SET stock_quantity = stock_quantity - NEW.quantity
    WHERE medicine_id = NEW.medicine_id;
    IF (SELECT stock_quantity FROM medicines WHERE medicine_id = NEW.medicine_id) < 0 THEN
        RAISE EXCEPTION 'Insufficient stock for medicine ID %', NEW.medicine_id;
    END IF;
    RETURN NEW;
END;
 $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reduce_stock
    BEFORE INSERT ON prescriptions
    FOR EACH ROW EXECUTE FUNCTION reduce_medicine_stock();

-- TRIGGER 2: Prevent booking appointments in the past
CREATE OR REPLACE FUNCTION prevent_past_appointment()
RETURNS TRIGGER AS $$ BEGIN
    IF NEW.appointment_date < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book appointment in the past';
    END IF;
    IF NEW.appointment_date = CURRENT_DATE AND NEW.appointment_time < CURRENT_TIME THEN
        RAISE EXCEPTION 'Cannot book appointment in the past';
    END IF;
    RETURN NEW;
END;
 $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_past
    BEFORE INSERT OR UPDATE ON appointments
    FOR EACH ROW EXECUTE FUNCTION prevent_past_appointment();

-- TRIGGER 3: Auto-update bill status when a payment is recorded
CREATE OR REPLACE FUNCTION update_bill_status()
RETURNS TRIGGER AS $$ DECLARE
    tb DECIMAL(10,2);
    tp DECIMAL(10,2);
BEGIN
    SELECT total_amount INTO tb FROM bills WHERE bill_id = NEW.bill_id;
    SELECT COALESCE(SUM(amount),0) INTO tp FROM payments WHERE bill_id = NEW.bill_id;
    IF tp >= tb THEN
        UPDATE bills SET status='Paid' WHERE bill_id=NEW.bill_id;
    ELSIF tp > 0 THEN
        UPDATE bills SET status='Partial' WHERE bill_id=NEW.bill_id;
    END IF;
    RETURN NEW;
END;
 $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_bill_status
    AFTER INSERT ON payments
    FOR EACH ROW EXECUTE FUNCTION update_bill_status();

-- ============================================================
-- VIEWS
-- ============================================================

-- VIEW 1: Doctor schedule with today's and upcoming counts
CREATE VIEW v_doctor_schedule AS
SELECT
    d.doctor_id, d.name AS doctor_name, d.specialization,
    dept.name AS department_name, d.available_days, d.fee,
    (SELECT COUNT(*) FROM appointments a
     WHERE a.doctor_id=d.doctor_id AND a.appointment_date=CURRENT_DATE
     AND a.status!='Cancelled') AS today_appts,
    (SELECT COUNT(*) FROM appointments a
     WHERE a.doctor_id=d.doctor_id AND a.appointment_date>=CURRENT_DATE
     AND a.status='Scheduled') AS upcoming_appts
FROM doctors d
JOIN departments dept ON d.dept_id=dept.dept_id;

-- VIEW 2: Complete patient medical history with prescribed medicines
CREATE VIEW v_patient_medical_history AS
SELECT
    p.patient_id, p.name AS patient_name, p.dob, p.gender, p.blood_group, p.phone,
    t.treatment_id, t.diagnosis, t.treatment_details, t.treatment_date,
    d.name AS treating_doctor, dept.name AS department,
    (SELECT STRING_AGG(m.name||' ('||pr.dosage||' x'||pr.duration_days||'d)', '; ')
     FROM prescriptions pr JOIN medicines m ON pr.medicine_id=m.medicine_id
     WHERE pr.treatment_id=t.treatment_id) AS prescribed_medicines
FROM patients p
LEFT JOIN treatments t ON p.patient_id=t.patient_id
LEFT JOIN doctors d ON t.doctor_id=d.doctor_id
LEFT JOIN departments dept ON d.dept_id=dept.dept_id;

-- VIEW 3: Appointment summary with derived display status
CREATE VIEW v_appointment_summary AS
SELECT
    a.appointment_id, p.name AS patient_name, d.name AS doctor_name,
    dept.name AS department, a.appointment_date, a.appointment_time,
    a.status, a.reason,
    CASE
        WHEN a.status='Completed' AND EXISTS(SELECT 1 FROM treatments t WHERE t.appointment_id=a.appointment_id)
            THEN 'Treated'
        WHEN a.status='Completed' THEN 'No Treatment Record'
        WHEN a.status='Scheduled' AND a.appointment_date<CURRENT_DATE THEN 'Overdue'
        ELSE a.status
    END AS display_status
FROM appointments a
JOIN patients p ON a.patient_id=p.patient_id
JOIN doctors d ON a.doctor_id=d.doctor_id
JOIN departments dept ON d.dept_id=dept.dept_id;

-- VIEW 4: Revenue analytics with window function ranking
CREATE VIEW v_revenue_analytics AS
SELECT
    pay.payment_id, pay.bill_id, p.name AS patient_name,
    pay.amount, pay.payment_method, pay.payment_date,
    b.total_amount AS bill_total,
    RANK() OVER (ORDER BY pay.amount DESC) AS payment_rank
FROM payments pay
JOIN bills b ON pay.bill_id=b.bill_id
JOIN patients p ON b.patient_id=p.patient_id;

-- ============================================================
-- STORED PROCEDURES
-- ============================================================

-- PROCEDURE 1: Automatic bill generation from appointment
CREATE OR REPLACE FUNCTION generate_bill(p_aid INTEGER)
RETURNS TABLE(bill_id INTEGER, patient_name VARCHAR(150), total_amount DECIMAL(10,2), status VARCHAR(20)) AS $$ DECLARE
    v_pid INTEGER;
    v_did INTEGER;
    v_fee DECIMAL(10,2);
    v_mcost DECIMAL(10,2);
    v_total DECIMAL(10,2);
    v_bid INTEGER;
    v_pname VARCHAR(150);
BEGIN
    SELECT patient_id, doctor_id INTO v_pid, v_did
    FROM appointments WHERE appointment_id = p_aid;
    IF v_pid IS NULL THEN
        RAISE EXCEPTION 'Appointment % not found', p_aid;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE appointment_id = p_aid) THEN
        RAISE EXCEPTION 'Bill already exists for appointment %', p_aid;
    END IF;
    SELECT fee INTO v_fee FROM doctors WHERE doctor_id = v_did;
    SELECT COALESCE(SUM(pr.quantity * m.unit_price), 0) INTO v_mcost
    FROM treatments t
    JOIN prescriptions pr ON t.treatment_id=pr.treatment_id
    JOIN medicines m ON pr.medicine_id=m.medicine_id
    WHERE t.appointment_id = p_aid;
    v_total := v_fee + v_mcost;
    SELECT name INTO v_pname FROM patients WHERE patient_id = v_pid;
    INSERT INTO bills (patient_id, appointment_id, consultation_fee, medicine_cost, total_amount, bill_date, status)
    VALUES (v_pid, p_aid, v_fee, v_mcost, v_total, CURRENT_DATE, 'Pending')
    RETURNING bill_id INTO v_bid;
    RETURN QUERY SELECT v_bid, v_pname, v_total, 'Pending'::VARCHAR(20);
END;
 $$ LANGUAGE plpgsql;

-- PROCEDURE 2: Department-wise statistics
CREATE OR REPLACE FUNCTION get_department_stats()
RETURNS TABLE(department_name VARCHAR(100), total_doctors BIGINT, total_patients BIGINT,
              total_appts BIGINT, total_revenue DECIMAL(10,2)) AS $$ BEGIN
    RETURN QUERY
    SELECT
        dept.name,
        COUNT(DISTINCT d.doctor_id),
        COUNT(DISTINCT a.patient_id),
        COUNT(a.appointment_id),
        COALESCE(SUM(b.total_amount), 0)
    FROM departments dept
    LEFT JOIN doctors d ON dept.dept_id=d.dept_id
    LEFT JOIN appointments a ON d.doctor_id=a.doctor_id
    LEFT JOIN bills b ON a.appointment_id=b.appointment_id
    GROUP BY dept.name ORDER BY dept.name;
END;
 $$ LANGUAGE plpgsql;

-- PROCEDURE 3: Restock medicine with validation
CREATE OR REPLACE FUNCTION restock_medicine(p_mid INTEGER, p_qty INTEGER)
RETURNS VARCHAR(100) AS $$ DECLARE
    v_old INT;
    v_name VARCHAR(200);
BEGIN
    SELECT stock_quantity, name INTO v_old, v_name
    FROM medicines WHERE medicine_id = p_mid;
    IF v_name IS NULL THEN
        RETURN 'ERROR: Medicine not found';
    END IF;
    UPDATE medicines SET stock_quantity = v_old + p_qty
    WHERE medicine_id = p_mid;
    RETURN 'OK: ' || v_name || ' ' || v_old || ' -> ' || (v_old + p_qty);
END;
 $$ LANGUAGE plpgsql;

-- ============================================================
-- SEED DATA
-- 30 Patients, 10 Doctors, 5 Departments, 50 Appointments,
-- 26 Treatments, 40+ Prescriptions, 15 Medicines, 26 Bills, 26 Payments
-- ============================================================

INSERT INTO departments (name, description) VALUES
('Cardiology', 'Heart and blood vessel disorders'),
('Neurology', 'Nervous system disorders'),
('Orthopedics', 'Musculoskeletal system'),
('General Medicine', 'Primary care'),
('Pediatrics', 'Child healthcare');

INSERT INTO doctors (name, specialization, phone, email, dept_id, experience_years, fee, available_days) VALUES
('Dr. Rajesh Kumar', 'Interventional Cardiology', '9876543210', 'rajesh.k@hosp.com', 1, 18, 1500, 'Mon,Wed,Fri'),
('Dr. Priya Sharma', 'Electrophysiology', '9876543211', 'priya.s@hosp.com', 1, 12, 1200, 'Tue,Thu,Sat'),
('Dr. Amit Verma', 'Stroke Neurology', '9876543212', 'amit.v@hosp.com', 2, 15, 1400, 'Mon,Tue,Thu'),
('Dr. Sneha Patel', 'Epilepsy Specialist', '9876543213', 'sneha.p@hosp.com', 2, 10, 1300, 'Wed,Fri,Sat'),
('Dr. Vikram Singh', 'Joint Replacement', '9876543214', 'vikram.s@hosp.com', 3, 20, 1800, 'Mon,Wed,Fri'),
('Dr. Anjali Gupta', 'Sports Medicine', '9876543215', 'anjali.g@hosp.com', 3, 8, 1100, 'Tue,Thu,Sat'),
('Dr. Suresh Reddy', 'Internal Medicine', '9876543216', 'suresh.r@hosp.com', 4, 22, 800, 'Mon-Fri'),
('Dr. Meena Iyer', 'Diabetology', '9876543217', 'meena.i@hosp.com', 4, 14, 900, 'Mon,Wed,Fri,Sat'),
('Dr. Rahul Joshi', 'Neonatology', '9876543218', 'rahul.j@hosp.com', 5, 11, 1000, 'Mon,Tue,Thu,Fri'),
('Dr. Kavita Nair', 'Developmental Pediatrics', '9876543219', 'kavita.n@hosp.com', 5, 9, 950, 'Wed,Thu,Sat');

UPDATE departments SET head_doctor_id=1 WHERE dept_id=1;
UPDATE departments SET head_doctor_id=3 WHERE dept_id=2;
UPDATE departments SET head_doctor_id=5 WHERE dept_id=3;
UPDATE departments SET head_doctor_id=7 WHERE dept_id=4;
UPDATE departments SET head_doctor_id=9 WHERE dept_id=5;

INSERT INTO patients (name, dob, gender, phone, email, address, blood_group) VALUES
('Arjun Mehta', '1985-03-15', 'Male', '9123456701', 'arjun.m@email.com', '12 MG Road Mumbai', 'O+'),
('Pooja Deshmukh', '1990-07-22', 'Female', '9123456702', 'pooja.d@email.com', '45 Shivaji Nagar Pune', 'A+'),
('Ravi Shankar', '1978-11-08', 'Male', '9123456703', 'ravi.s@email.com', '78 Banjara Hills Hyderabad', 'B+'),
('Neha Kapoor', '1995-01-30', 'Female', '9123456704', 'neha.k@email.com', '23 Connaught Place Delhi', 'AB+'),
('Suresh Nair', '1982-06-17', 'Male', '9123456705', 'suresh.n@email.com', '56 Marine Drive Kochi', 'A-'),
('Kavitha Ramaswamy', '1988-09-25', 'Female', '9123456706', 'kavitha.r@email.com', '89 T Nagar Chennai', 'B-'),
('Manoj Tiwari', '1975-04-12', 'Male', '9123456707', 'manoj.t@email.com', '34 Hazratganj Lucknow', 'O-'),
('Anita Singh', '1992-12-03', 'Female', '9123456708', 'anita.s@email.com', '67 Civil Lines Jaipur', 'A+'),
('Deepak Joshi', '1980-08-20', 'Male', '9123456709', 'deepak.j@email.com', '91 Ashram Road Ahmedabad', 'AB-'),
('Shalini Gupta', '1993-02-14', 'Female', '9123456710', 'shalini.g@email.com', '15 Park Street Kolkata', 'O+'),
('Rajiv Malhotra', '1972-10-05', 'Male', '9123456711', 'rajiv.m@email.com', '43 Sector 17 Chandigarh', 'B+'),
('Meera Krishnan', '1987-05-28', 'Female', '9123456712', 'meera.k@email.com', '72 Anna Nagar Chennai', 'A-'),
('Vikas Chauhan', '1991-07-19', 'Male', '9123456713', 'vikas.c@email.com', '28 Gomti Nagar Lucknow', 'O+'),
('Priti Banerjee', '1986-11-11', 'Female', '9123456714', 'priti.b@email.com', '56 Salt Lake Kolkata', 'AB+'),
('Arun Patel', '1979-03-03', 'Male', '9123456715', 'arun.p@email.com', '81 Satellite Ahmedabad', 'B-'),
('Sunita Verma', '1994-08-07', 'Female', '9123456716', 'sunita.v@email.com', '19 Rohini Delhi', 'A+'),
('Kiran Rao', '1983-01-22', 'Male', '9123456717', 'kiran.r@email.com', '64 Jubilee Hills Hyderabad', 'O-'),
('Divya Saxena', '1996-06-15', 'Female', '9123456718', 'divya.s@email.com', '37 Vaishali Nagar Jaipur', 'B+'),
('Mohan Das', '1970-12-30', 'Male', '9123456719', 'mohan.d@email.com', '48 Bhubaneswar Odisha', 'A+'),
('Rekha Menon', '1989-04-18', 'Female', '9123456720', 'rekha.m@email.com', '93 Edappally Kochi', 'AB-'),
('Sanjay Mishra', '1976-09-09', 'Male', '9123456721', 'sanjay.m@email.com', '25 Lalbagh Lucknow', 'O+'),
('Anjali Desai', '1997-02-27', 'Female', '9123456722', 'anjali.d@email.com', '61 Koregaon Park Pune', 'B+'),
('Pradeep Kumar', '1981-07-14', 'Male', '9123456723', 'pradeep.k@email.com', '14 Dwarakanagar Vizag', 'A-'),
('Lakshmi Iyer', '1984-11-23', 'Female', '9123456724', 'lakshmi.i@email.com', '77 Mylapore Chennai', 'O+'),
('Rahul Sharma', '1990-05-06', 'Male', '9123456725', 'rahul.s@email.com', '39 Andheri Mumbai', 'AB+'),
('Geeta Rani', '1988-10-16', 'Female', '9123456726', 'geeta.r@email.com', '52 Model Town Delhi', 'B-'),
('Ashok Pandey', '1974-08-01', 'Male', '9123456727', 'ashok.p@email.com', '86 Patna Bihar', 'A+'),
('Nisha Agarwal', '1993-03-20', 'Female', '9123456728', 'nisha.a@email.com', '11 Malviya Nagar Jaipur', 'O-'),
('Tarun Bhatt', '1986-12-12', 'Male', '9123456729', 'tarun.b@email.com', '47 Dehradun UK', 'B+'),
('Swati Kulkarni', '1991-06-29', 'Female', '9123456730', 'swati.k@email.com', '73 Kothrud Pune', 'A+');

INSERT INTO appointments (patient_id, doctor_id, appointment_date, appointment_time, status, reason) VALUES
(1, 1, '2025-01-05', '09:00', 'Completed', 'Chest pain and shortness of breath'),
(2, 2, '2025-01-06', '10:30', 'Completed', 'Irregular heartbeat palpitations'),
(3, 3, '2025-01-07', '11:00', 'Completed', 'Recurring headaches and dizziness'),
(4, 4, '2025-01-08', '14:00', 'Completed', 'Seizure episode evaluation'),
(5, 5, '2025-01-09', '09:30', 'Completed', 'Knee pain and difficulty walking'),
(6, 6, '2025-01-10', '11:30', 'Completed', 'Shoulder injury from sports'),
(7, 7, '2025-01-11', '10:00', 'Completed', 'Persistent fever and fatigue'),
(8, 8, '2025-01-12', '15:00', 'Completed', 'High blood sugar management'),
(9, 1, '2025-01-13', '09:00', 'Completed', 'Follow-up cardiac evaluation'),
(10, 3, '2025-01-14', '10:30', 'Completed', 'Migraine with aura symptoms'),
(11, 5, '2025-01-15', '11:00', 'Completed', 'Hip replacement consultation'),
(12, 7, '2025-01-16', '14:00', 'Completed', 'Chronic cough and cold'),
(13, 9, '2025-01-17', '09:30', 'Completed', 'Child vaccination follow-up'),
(14, 2, '2025-01-18', '10:00', 'Completed', 'ECG abnormality review'),
(15, 4, '2025-01-19', '11:30', 'Completed', 'Numbness in left arm'),
(16, 6, '2025-07-20', '09:00', 'Scheduled', 'Ankle sprain follow-up'),
(17, 8, '2025-07-21', '10:30', 'Scheduled', 'Diabetes routine checkup'),
(18, 10, '2025-07-22', '11:00', 'Scheduled', 'Child developmental assessment'),
(19, 1, '2025-07-23', '14:00', 'Scheduled', 'Post-angioplasty review'),
(20, 3, '2025-07-24', '09:30', 'Scheduled', 'Neurological follow-up'),
(21, 5, '2025-07-25', '10:00', 'Scheduled', 'Post-surgery knee check'),
(22, 7, '2025-07-26', '11:30', 'Scheduled', 'General health checkup'),
(23, 9, '2025-07-27', '15:00', 'Scheduled', 'Newborn checkup'),
(24, 2, '2025-07-28', '09:00', 'Scheduled', 'Heart rhythm monitoring'),
(25, 4, '2025-07-29', '10:30', 'Scheduled', 'Epilepsy medication review'),
(26, 6, '2025-08-01', '11:00', 'Scheduled', 'Physiotherapy assessment'),
(27, 8, '2025-08-02', '14:00', 'Scheduled', 'Insulin adjustment review'),
(28, 10, '2025-08-03', '09:30', 'Scheduled', 'Growth monitoring'),
(29, 1, '2025-08-04', '10:00', 'Scheduled', 'Stress test evaluation'),
(30, 3, '2025-08-05', '11:30', 'Scheduled', 'MRI results discussion'),
(1, 7, '2025-02-10', '10:00', 'Cancelled', 'Rescheduled'),
(5, 1, '2025-02-12', '09:00', 'Cancelled', 'Patient unable to attend'),
(9, 4, '2025-02-15', '14:00', 'Cancelled', 'Doctor unavailable'),
(13, 6, '2025-02-18', '11:00', 'Cancelled', 'Patient recovered'),
(3, 7, '2025-02-20', '10:00', 'No-Show', 'Patient did not arrive'),
(8, 1, '2025-02-22', '09:30', 'No-Show', 'Patient did not arrive'),
(20, 2, '2025-03-01', '10:00', 'Completed', 'Cardiac stress test'),
(21, 4, '2025-03-03', '11:30', 'Completed', 'Nerve conduction study'),
(22, 6, '2025-03-05', '09:00', 'Completed', 'Back pain evaluation'),
(23, 8, '2025-03-07', '14:00', 'Completed', 'Thyroid function review'),
(24, 10, '2025-03-09', '10:30', 'Completed', 'Child nutrition counseling'),
(25, 1, '2025-03-11', '09:00', 'Completed', 'Blood pressure management'),
(26, 3, '2025-03-13', '11:00', 'Completed', 'Vertigo treatment review'),
(27, 5, '2025-03-15', '10:00', 'Completed', 'Spine surgery consultation'),
(28, 7, '2025-03-17', '15:00', 'Completed', 'Allergy testing follow-up'),
(29, 9, '2025-03-19', '09:30', 'Completed', 'Pediatric fever evaluation'),
(30, 2, '2025-03-21', '11:30', 'Completed', 'Pacemaker check');

INSERT INTO medicines (name, category, dosage_form, unit_price, stock_quantity, reorder_level, manufacturer) VALUES
('Aspirin 75mg', 'Pain Relief', 'Tablet', 5.50, 500, 100, 'Cipla Ltd'),
('Metformin 500mg', 'Antidiabetic', 'Tablet', 8.00, 350, 80, 'Sun Pharma'),
('Amlodipine 5mg', 'Antihypertensive', 'Tablet', 12.00, 400, 100, 'Dr Reddys'),
('Omeprazole 20mg', 'Antacid', 'Capsule', 15.00, 300, 60, 'Cipla Ltd'),
('Paracetamol 500mg', 'Analgesic', 'Tablet', 3.00, 800, 150, 'GSK Pharma'),
('Amoxicillin 250mg', 'Antibiotic', 'Capsule', 18.00, 200, 50, 'Alkem Labs'),
('Cetirizine 10mg', 'Antihistamine', 'Tablet', 6.50, 450, 80, 'Mankind Pharma'),
('Ibuprofen 400mg', 'NSAID', 'Tablet', 7.00, 380, 75, 'Abbott India'),
('Atorvastatin 10mg', 'Statin', 'Tablet', 22.00, 250, 50, 'Pfizer India'),
('Levetiracetam 500mg', 'Antiepileptic', 'Tablet', 45.00, 120, 30, 'Sun Pharma'),
('Pantoprazole 40mg', 'PPI', 'Tablet', 20.00, 280, 60, 'Alkem Labs'),
('Diclofenac Gel', 'Topical', 'Cream', 85.00, 150, 30, 'Novartis India'),
('Salbutamol Syrup', 'Bronchodilator', 'Syrup', 35.00, 180, 40, 'Cipla Ltd'),
('Vitamin D3 60K IU', 'Supplement', 'Capsule', 28.00, 600, 100, 'USV Ltd'),
('Calcium 500mg', 'Supplement', 'Tablet', 10.00, 450, 80, 'Zydus Cadila');

INSERT INTO treatments (appointment_id, patient_id, doctor_id, diagnosis, treatment_details, treatment_date, notes) VALUES
(1, 1, 1, 'Coronary Artery Disease', 'Angiography performed, medication started', '2025-01-05', 'Follow-up in 2 weeks'),
(2, 2, 2, 'Atrial Fibrillation', 'Rate control medication, ECG monitoring', '2025-01-06', 'Beta blockers initiated'),
(3, 3, 3, 'Tension-Type Headache', 'Pain management and lifestyle modifications', '2025-01-07', 'Stress reduction advised'),
(4, 4, 4, 'Focal Seizure Disorder', 'Antiepileptic medication, EEG scheduled', '2025-01-08', 'MRI brain ordered'),
(5, 5, 5, 'Osteoarthritis Right Knee', 'Conservative management with physiotherapy', '2025-01-09', 'Weight reduction recommended'),
(6, 6, 6, 'Rotator Cuff Tendinitis', 'Anti-inflammatory and physiotherapy', '2025-01-10', 'Avoid overhead activities'),
(7, 7, 7, 'Upper Respiratory Tract Infection', 'Antibiotics and symptomatic treatment', '2025-01-11', 'Complete antibiotic course'),
(8, 8, 8, 'Type 2 Diabetes Mellitus', 'Oral hypoglycemic adjustment, diet plan', '2025-01-12', 'HbA1c target < 7%'),
(9, 1, 1, 'Stable Angina', 'Medication optimization', '2025-01-13', 'Nitroglycerin prescribed'),
(10, 10, 3, 'Migraine with Aura', 'Preventive medication and trigger avoidance', '2025-01-14', 'Keep headache diary'),
(11, 11, 5, 'Avascular Necrosis Hip', 'Surgical consultation advised', '2025-01-15', 'MRI hip confirmed'),
(12, 12, 7, 'Acute Bronchitis', 'Antibiotics and bronchodilator', '2025-01-16', 'Chest X-ray normal'),
(13, 13, 9, 'Normal Growth Vaccination', 'Routine immunization completed', '2025-01-17', 'Next vaccination in 1 month'),
(14, 14, 2, 'Sinus Bradycardia', 'Monitoring advised', '2025-01-18', 'Holter monitoring scheduled'),
(15, 15, 4, 'Peripheral Neuropathy', 'Vitamin supplementation and pain management', '2025-01-19', 'Nerve conduction study done'),
(20, 20, 2, 'Hypertensive Heart Disease', 'BP medication optimization', '2025-03-01', 'Salt restriction advised'),
(21, 21, 4, 'Carpal Tunnel Syndrome', 'Wrist splint and anti-inflammatory', '2025-03-03', 'Surgery if no improvement'),
(22, 22, 6, 'Lumbar Disc Prolapse', 'Conservative management, physiotherapy', '2025-03-05', 'MRI lumbar done'),
(23, 23, 8, 'Hypothyroidism', 'Thyroid hormone replacement adjusted', '2025-03-07', 'TSH recheck in 6 weeks'),
(24, 24, 10, 'Failure to Thrive', 'Nutritional assessment and supplementation', '2025-03-09', 'Diet chart provided'),
(25, 25, 1, 'Essential Hypertension', 'Combination antihypertensive therapy', '2025-03-11', 'Daily BP monitoring'),
(26, 26, 3, 'Benign Paroxysmal Positional Vertigo', 'Epley maneuver performed', '2025-03-13', 'Vestibular exercises taught'),
(27, 27, 5, 'Degenerative Disc Disease', 'Pain management and rehabilitation', '2025-03-15', 'Epidural injection discussed'),
(28, 28, 7, 'Allergic Rhinitis', 'Antihistamines and nasal spray', '2025-03-17', 'Allergen avoidance advised'),
(29, 29, 9, 'Acute Gastroenteritis', 'ORS and probiotics', '2025-03-19', 'Hydration maintained'),
(30, 30, 2, 'Complete Heart Block', 'Pacemaker implanted', '2025-03-21', 'Post-op recovery good');

INSERT INTO prescriptions (treatment_id, medicine_id, quantity, dosage, duration_days, instructions) VALUES
(1, 1, 30, 'Once daily', 30, 'Take after breakfast'),
(1, 9, 30, 'Once daily at bedtime', 30, 'Take on empty stomach'),
(2, 3, 30, 'Once daily', 30, 'Monitor pulse regularly'),
(3, 7, 20, 'Once daily at night', 20, 'May cause drowsiness'),
(3, 8, 15, 'As needed max 3/day', 15, 'Take with food'),
(4, 10, 60, 'Twice daily', 30, 'Do not stop suddenly'),
(5, 8, 30, 'Twice daily', 15, 'Take with food'),
(5, 12, 1, 'Apply 3 times daily', 15, 'Massage on knee'),
(5, 14, 30, 'Once daily', 30, 'Take with milk'),
(6, 8, 20, 'Twice daily', 10, 'Take with food'),
(6, 12, 1, 'Apply twice daily', 10, 'On shoulder area'),
(7, 5, 20, 'Three times daily', 7, 'For fever'),
(7, 6, 21, 'Three times daily', 7, 'Complete the course'),
(8, 2, 60, 'Twice daily after meals', 30, 'Monitor blood sugar'),
(9, 1, 30, 'Once daily', 30, 'Take after breakfast'),
(9, 3, 30, 'Once daily', 30, 'Monitor BP'),
(10, 7, 30, 'Once daily at night', 30, 'Preventive use'),
(11, 8, 30, 'As needed', 15, 'For pain relief'),
(11, 14, 30, 'Once daily', 30, 'Bone health'),
(12, 6, 21, 'Three times daily', 7, 'Complete course'),
(12, 13, 1, '5ml twice daily', 7, 'For cough'),
(13, 5, 10, 'As needed for fever', 5, 'Post-vaccination care'),
(14, 9, 30, 'Once daily', 30, 'Heart health'),
(15, 14, 60, 'Once daily', 60, 'Nerve health'),
(15, 8, 20, 'As needed', 15, 'For nerve pain'),
(20, 3, 30, 'Once daily', 30, 'BP control'),
(20, 9, 30, 'Once daily', 30, 'Cholesterol management'),
(21, 8, 20, 'Twice daily', 10, 'Anti-inflammatory'),
(22, 8, 30, 'Twice daily', 15, 'With food'),
(22, 12, 2, 'Apply twice daily', 15, 'On lower back'),
(23, 15, 60, 'Once daily on empty stomach', 60, 'Wait 30 min before eating'),
(24, 14, 30, 'Once daily', 30, 'With milk'),
(24, 15, 30, 'Once daily', 30, 'Calcium supplement'),
(25, 3, 30, 'Once daily', 30, 'Morning dose'),
(25, 1, 30, 'Once daily', 30, 'Blood thinner'),
(26, 7, 10, 'Once daily at night', 10, 'For dizziness'),
(27, 8, 30, 'Twice daily', 15, 'Pain management'),
(27, 14, 30, 'Once daily', 30, 'Bone support'),
(28, 7, 30, 'Once daily', 30, 'Antihistamine'),
(28, 4, 30, 'Once daily before breakfast', 30, 'Prevent stomach upset'),
(29, 4, 10, 'Once daily', 5, 'With food'),
(30, 1, 30, 'Once daily', 30, 'Post-pacemaker'),
(30, 3, 30, 'Once daily', 30, 'BP management');

INSERT INTO bills (patient_id, appointment_id, consultation_fee, medicine_cost, total_amount, bill_date, status) VALUES
(1, 1, 1500, 825, 2325, '2025-01-05', 'Paid'),
(2, 2, 1200, 360, 1560, '2025-01-06', 'Paid'),
(3, 3, 1400, 355, 1755, '2025-01-07', 'Paid'),
(4, 4, 1300, 2700, 4000, '2025-01-08', 'Paid'),
(5, 5, 1800, 410, 2210, '2025-01-09', 'Paid'),
(6, 6, 1100, 245, 1345, '2025-01-10', 'Paid'),
(7, 7, 800, 498, 1298, '2025-01-11', 'Paid'),
(8, 8, 900, 480, 1380, '2025-01-12', 'Paid'),
(1, 9, 1500, 810, 2310, '2025-01-13', 'Paid'),
(10, 10, 1400, 195, 1595, '2025-01-14', 'Paid'),
(11, 11, 1800, 530, 2330, '2025-01-15', 'Paid'),
(12, 12, 800, 513, 1313, '2025-01-16', 'Paid'),
(13, 13, 1000, 30, 1030, '2025-01-17', 'Paid'),
(14, 14, 1200, 660, 1860, '2025-01-18', 'Paid'),
(15, 15, 1300, 1180, 2480, '2025-01-19', 'Paid'),
(20, 20, 1200, 1020, 2220, '2025-03-01', 'Paid'),
(21, 21, 1300, 140, 1440, '2025-03-03', 'Paid'),
(22, 22, 1100, 580, 1680, '2025-03-05', 'Paid'),
(23, 23, 900, 840, 1740, '2025-03-07', 'Paid'),
(24, 24, 950, 1140, 2090, '2025-03-09', 'Paid'),
(25, 25, 1500, 510, 2010, '2025-03-11', 'Paid'),
(26, 26, 1400, 65, 1465, '2025-03-13', 'Paid'),
(27, 27, 1800, 790, 2590, '2025-03-15', 'Paid'),
(28, 28, 800, 690, 1490, '2025-03-17', 'Paid'),
(29, 29, 1000, 200, 1200, '2025-03-19', 'Paid'),
(30, 30, 1200, 810, 2010, '2025-03-21', 'Paid');

INSERT INTO payments (bill_id, amount, payment_method, payment_date, reference_number) VALUES
(1, 2325, 'Card', '2025-01-05', 'TXN001'),
(2, 1560, 'UPI', '2025-01-06', 'TXN002'),
(3, 1755, 'Cash', '2025-01-07', 'TXN003'),
(4, 4000, 'Card', '2025-01-08', 'TXN004'),
(5, 2210, 'Insurance', '2025-01-09', 'INS001'),
(6, 1345, 'UPI', '2025-01-10', 'TXN006'),
(7, 1298, 'Cash', '2025-01-11', 'TXN007'),
(8, 1380, 'Card', '2025-01-12', 'TXN008'),
(9, 2310, 'Insurance', '2025-01-13', 'INS002'),
(10, 1595, 'UPI', '2025-01-14', 'TXN010'),
(11, 2330, 'Cash', '2025-01-15', 'TXN011'),
(12, 1313, 'Card', '2025-01-16', 'TXN012'),
(13, 1030, 'Cash', '2025-01-17', 'TXN013'),
(14, 1860, 'UPI', '2025-01-18', 'TXN014'),
(15, 2480, 'Insurance', '2025-01-19', 'INS003'),
(16, 2220, 'Card', '2025-03-01', 'TXN016'),
(17, 1440, 'UPI', '2025-03-03', 'TXN017'),
(18, 1680, 'Cash', '2025-03-05', 'TXN018'),
(19, 1740, 'Card', '2025-03-07', 'TXN019'),
(20, 2090, 'Insurance', '2025-03-09', 'INS004'),
(21, 2010, 'UPI', '2025-03-11', 'TXN021'),
(22, 1465, 'Cash', '2025-03-13', 'TXN022'),
(23, 2590, 'Card', '2025-03-15', 'TXN023'),
(24, 1490, 'UPI', '2025-03-17', 'TXN024'),
(25, 1200, 'Cash', '2025-03-19', 'TXN025'),
(26, 2010, 'Insurance', '2025-03-21', 'INS005');

-- Verification
SELECT 'Departments' AS tbl, COUNT(*) FROM departments
UNION ALL SELECT 'Doctors', COUNT(*) FROM doctors
UNION ALL SELECT 'Patients', COUNT(*) FROM patients
UNION ALL SELECT 'Appointments', COUNT(*) FROM appointments
UNION ALL SELECT 'Treatments', COUNT(*) FROM treatments
UNION ALL SELECT 'Medicines', COUNT(*) FROM medicines
UNION ALL SELECT 'Prescriptions', COUNT(*) FROM prescriptions
UNION ALL SELECT 'Bills', COUNT(*) FROM bills
UNION ALL SELECT 'Payments', COUNT(*) FROM payments;
