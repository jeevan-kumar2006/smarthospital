import os
from flask import Flask, render_template, request, redirect, url_for, jsonify
from dotenv import load_dotenv
import psycopg2
from psycopg2.extras import RealDictCursor

load_dotenv()

app = Flask(__name__, template_folder="ui/templates", static_folder="ui")
app.secret_key = os.getenv("SECRET_KEY", "dev")

DB_CONFIG = dict(
    host=os.getenv("DB_HOST", "localhost"),
    port=os.getenv("DB_PORT", "5432"),
    dbname=os.getenv("DB_NAME", "hospital_db"),
    user=os.getenv("DB_USER", "postgres"),
    password=os.getenv("DB_PASSWORD", ""),
    cursor_factory=RealDictCursor,
)


def db(query, params=None, fetch=False, one=False):
    conn = psycopg2.connect(**DB_CONFIG)
    try:
        cur = conn.cursor()
        cur.execute(query, params or ())
        if one:
            r = cur.fetchone()
        elif fetch:
            r = cur.fetchall()
        else:
            r = None
        conn.commit()
        return r
    except Exception as e:
        conn.rollback()
        raise e
    finally:
        conn.close()


# ==================== DASHBOARD ====================
@app.route("/")
def dashboard():
    tp = db("SELECT COUNT(*) AS c FROM patients", one=True)["c"]
    td = db("SELECT COUNT(*) AS c FROM doctors", one=True)["c"]
    ta = db("SELECT COUNT(*) AS c FROM appointments", one=True)["c"]
    tr = db("SELECT COALESCE(SUM(amount),0) AS t FROM payments", one=True)["t"]
    tm = db("SELECT COUNT(*) AS c FROM medicines WHERE stock_quantity>0", one=True)["c"]
    ra = db("""SELECT a.appointment_id, p.name AS pn, d.name AS dn, a.appointment_date, a.status
               FROM appointments a JOIN patients p ON a.patient_id=p.patient_id
               JOIN doctors d ON a.doctor_id=d.doctor_id ORDER BY a.created_at DESC LIMIT 8""", fetch=True)
    rp = db("""SELECT pay.payment_id, p.name AS pn, pay.amount, pay.payment_date, pay.payment_method
               FROM payments pay JOIN bills b ON pay.bill_id=b.bill_id
               JOIN patients p ON b.patient_id=p.patient_id ORDER BY pay.payment_date DESC LIMIT 5""", fetch=True)
    ls = db("SELECT * FROM medicines WHERE stock_quantity<=reorder_level ORDER BY stock_quantity LIMIT 5", fetch=True)
    ua = db("""SELECT a.appointment_id, p.name AS pn, d.name AS dn, a.appointment_date, a.appointment_time
               FROM appointments a JOIN patients p ON a.patient_id=p.patient_id
               JOIN doctors d ON a.doctor_id=d.doctor_id
               WHERE a.appointment_date>=CURRENT_DATE AND a.status='Scheduled'
               ORDER BY a.appointment_date, a.appointment_time LIMIT 5""", fetch=True)
    return render_template("pages.html", page="dashboard", tp=tp, td=td, ta=ta, tr=float(tr), tm=tm, ra=ra, rp=rp, ls=ls, ua=ua)


# ==================== PATIENTS ====================
@app.route("/patients/")
def patients_list():
    s = request.args.get("search", "")
    if s:
        rows = db("SELECT * FROM patients WHERE name ILIKE %s OR phone ILIKE %s ORDER BY created_at DESC",
                  (f"%{s}%", f"%{s}%"), fetch=True)
    else:
        rows = db("SELECT * FROM patients ORDER BY created_at DESC", fetch=True)
    return render_template("pages.html", page="patients", patients=rows, search=s)


@app.route("/patients/add", methods=["GET", "POST"])
def patients_add():
    if request.method == "POST":
        db("""INSERT INTO patients (name,dob,gender,phone,email,address,blood_group)
              VALUES(%s,%s,%s,%s,%s,%s,%s)""",
            (request.form["name"], request.form["dob"], request.form["gender"],
             request.form["phone"], request.form.get("email"), request.form.get("address"), request.form.get("blood_group")))
        return redirect("/patients/")
    return render_template("pages.html", page="patient_form")


@app.route("/patients/edit/<int:pid>", methods=["GET", "POST"])
def patients_edit(pid):
    p = db("SELECT * FROM patients WHERE patient_id=%s", (pid,), one=True)
    if request.method == "POST":
        db("""UPDATE patients SET name=%s,dob=%s,gender=%s,phone=%s,email=%s,address=%s,blood_group=%s
              WHERE patient_id=%s""",
            (request.form["name"], request.form["dob"], request.form["gender"],
             request.form["phone"], request.form.get("email"), request.form.get("address"),
             request.form.get("blood_group"), pid))
        return redirect("/patients/")
    return render_template("pages.html", page="patient_form", patient=p, edit=True)


@app.route("/patients/delete/<int:pid>", methods=["POST"])
def patients_delete(pid):
    db("DELETE FROM patients WHERE patient_id=%s", (pid,))
    return redirect("/patients/")


@app.route("/patients/history/<int:pid>")
def patients_history(pid):
    p = db("SELECT * FROM patients WHERE patient_id=%s", (pid,), one=True)
    hist = db("""SELECT t.*, d.name AS dn, dept.name AS depn FROM treatments t
                 JOIN doctors d ON t.doctor_id=d.doctor_id JOIN departments dept ON d.dept_id=dept.dept_id
                 WHERE t.patient_id=%s ORDER BY t.treatment_date DESC""", (pid,), fetch=True)
    pres = db("""SELECT pr.*, m.name AS mn FROM prescriptions pr JOIN medicines m ON pr.medicine_id=m.medicine_id
                 JOIN treatments t ON pr.treatment_id=t.treatment_id
                 WHERE t.patient_id=%s ORDER BY t.treatment_date DESC""", (pid,), fetch=True)
    apts = db("""SELECT a.*, d.name AS dn FROM appointments a JOIN doctors d ON a.doctor_id=d.doctor_id
                 WHERE a.patient_id=%s ORDER BY a.appointment_date DESC""", (pid,), fetch=True)
    bills = db("SELECT * FROM bills WHERE patient_id=%s ORDER BY bill_date DESC", (pid,), fetch=True)
    for b in bills:
        b["paid"] = db("SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE bill_id=%s", (b["bill_id"],), one=True)["t"]
    return render_template("pages.html", page="patient_history", patient=p, hist=hist, pres=pres, apts=apts, bills=bills)


@app.route("/patients/api/search")
def patients_api_search():
    q = request.args.get("q", "")
    rows = db("SELECT patient_id,name,phone,blood_group FROM patients WHERE name ILIKE %s LIMIT 10",
              (f"%{q}%",), fetch=True)
    return jsonify([dict(r) for r in rows])


# ==================== DOCTORS ====================
@app.route("/doctors/")
def doctors_list():
    rows = db("""SELECT d.*, dept.name AS depn FROM doctors d
                 LEFT JOIN departments dept ON d.dept_id=dept.dept_id ORDER BY d.doctor_id""", fetch=True)
    return render_template("pages.html", page="doctors", doctors=rows)


@app.route("/doctors/add", methods=["GET", "POST"])
def doctors_add():
    depts = db("SELECT * FROM departments ORDER BY name", fetch=True)
    if request.method == "POST":
        db("""INSERT INTO doctors (name,specialization,phone,email,dept_id,experience_years,fee,available_days)
              VALUES(%s,%s,%s,%s,%s,%s,%s,%s)""",
            (request.form["name"], request.form["specialization"], request.form["phone"],
             request.form.get("email"), request.form["dept_id"], request.form.get("experience_years"),
             request.form["fee"], request.form.get("available_days")))
        return redirect("/doctors/")
    return render_template("pages.html", page="doctor_form", depts=depts)


@app.route("/doctors/edit/<int:did>", methods=["GET", "POST"])
def doctors_edit(did):
    doc = db("SELECT * FROM doctors WHERE doctor_id=%s", (did,), one=True)
    depts = db("SELECT * FROM departments ORDER BY name", fetch=True)
    if request.method == "POST":
        db("""UPDATE doctors SET name=%s,specialization=%s,phone=%s,email=%s,dept_id=%s,
              experience_years=%s,fee=%s,available_days=%s WHERE doctor_id=%s""",
            (request.form["name"], request.form["specialization"], request.form["phone"],
             request.form.get("email"), request.form["dept_id"], request.form.get("experience_years"),
             request.form["fee"], request.form.get("available_days"), did))
        return redirect("/doctors/")
    return render_template("pages.html", page="doctor_form", doctor=doc, depts=depts, edit=True)


@app.route("/doctors/delete/<int:did>", methods=["POST"])
def doctors_delete(did):
    db("DELETE FROM doctors WHERE doctor_id=%s", (did,))
    return redirect("/doctors/")


@app.route("/doctors/schedule")
def doctors_schedule():
    rows = db("""SELECT d.*, dept.name AS depn FROM doctors d
                 JOIN departments dept ON d.dept_id=dept.dept_id ORDER BY dept.name, d.name""", fetch=True)
    return render_template("pages.html", page="doctor_schedule", schedules=rows)


# ==================== APPOINTMENTS ====================
@app.route("/appointments/")
def appointments_list():
    sf = request.args.get("status", "")
    q = """SELECT a.*, p.name AS pn, d.name AS dn, dept.name AS depn
           FROM appointments a JOIN patients p ON a.patient_id=p.patient_id
           JOIN doctors d ON a.doctor_id=d.doctor_id JOIN departments dept ON d.dept_id=dept.dept_id"""
    params = ()
    if sf:
        q += " WHERE a.status=%s"
        params = (sf,)
    q += " ORDER BY a.appointment_date DESC, a.appointment_time DESC"
    return render_template("pages.html", page="appointments", appointments=db(q, params, fetch=True), sf=sf)


@app.route("/appointments/book", methods=["GET", "POST"])
def appointments_book():
    pts = db("SELECT patient_id,name FROM patients ORDER BY name", fetch=True)
    docs = db("""SELECT d.doctor_id,d.name,d.specialization,dept.name AS depn
                 FROM doctors d JOIN departments dept ON d.dept_id=dept.dept_id ORDER BY d.name""", fetch=True)
    if request.method == "POST":
        try:
            db("""INSERT INTO appointments (patient_id,doctor_id,appointment_date,appointment_time,reason,status)
                  VALUES(%s,%s,%s,%s,%s,'Scheduled')""",
                (request.form["patient_id"], request.form["doctor_id"],
                 request.form["appointment_date"], request.form["appointment_time"], request.form.get("reason")))
            return redirect("/appointments/")
        except Exception as e:
            return render_template("pages.html", page="appointment_form", pts=pts, docs=docs, error=str(e))
    return render_template("pages.html", page="appointment_form", pts=pts, docs=docs)


@app.route("/appointments/update-status/<int:aid>", methods=["POST"])
def appointments_update(aid):
    db("UPDATE appointments SET status=%s WHERE appointment_id=%s", (request.form["status"], aid))
    return redirect("/appointments/")


@app.route("/appointments/cancel/<int:aid>", methods=["POST"])
def appointments_cancel(aid):
    db("UPDATE appointments SET status='Cancelled' WHERE appointment_id=%s", (aid,))
    return redirect("/appointments/")


# ==================== TREATMENTS ====================
@app.route("/treatments/")
def treatments_list():
    rows = db("""SELECT t.treatment_id, t.diagnosis, t.treatment_date, p.name AS pn, d.name AS dn, dept.name AS depn
                 FROM treatments t JOIN patients p ON t.patient_id=p.patient_id
                 JOIN doctors d ON t.doctor_id=d.doctor_id JOIN departments dept ON d.dept_id=dept.dept_id
                 ORDER BY t.treatment_date DESC""", fetch=True)
    return render_template("pages.html", page="treatments", treatments=rows)


@app.route("/treatments/add", methods=["GET", "POST"])
def treatments_add():
    apts = db("""SELECT a.appointment_id, p.name AS pn, d.name AS dn, a.appointment_date, a.reason
                 FROM appointments a JOIN patients p ON a.patient_id=p.patient_id
                 JOIN doctors d ON a.doctor_id=d.doctor_id
                 WHERE a.status='Completed' AND a.appointment_id NOT IN (SELECT appointment_id FROM treatments)
                 ORDER BY a.appointment_date DESC""", fetch=True)
    meds = db("SELECT * FROM medicines WHERE stock_quantity>0 ORDER BY name", fetch=True)
    if request.method == "POST":
        aid = request.form["appointment_id"]
        apt = db("SELECT patient_id,doctor_id FROM appointments WHERE appointment_id=%s", (aid,), one=True)
        tr = db("""INSERT INTO treatments (appointment_id,patient_id,doctor_id,diagnosis,treatment_details,treatment_date,notes)
                   VALUES(%s,%s,%s,%s,%s,%s,%s) RETURNING treatment_id""",
                 (aid, apt["patient_id"], apt["doctor_id"], request.form["diagnosis"],
                  request.form["treatment_details"], request.form["treatment_date"], request.form.get("notes", "")), one=True)
        tid = tr["treatment_id"]
        mids = request.form.getlist("medicine_id[]")
        qtys = request.form.getlist("quantity[]")
        doss = request.form.getlist("dosage[]")
        durs = request.form.getlist("duration_days[]")
        insts = request.form.getlist("instructions[]")
        for i in range(len(mids)):
            if mids[i]:
                db("""INSERT INTO prescriptions (treatment_id,medicine_id,quantity,dosage,duration_days,instructions)
                      VALUES(%s,%s,%s,%s,%s,%s)""",
                    (tid, mids[i], qtys[i], doss[i], durs[i], insts[i]))
        return redirect("/treatments/")
    return render_template("pages.html", page="treatment_form", apts=apts, meds=meds)


# ==================== MEDICINES ====================
@app.route("/medicines/")
def medicines_list():
    rows = db("""SELECT m.*, CASE WHEN m.stock_quantity<=m.reorder_level THEN TRUE ELSE FALSE END AS low
                 FROM medicines m ORDER BY m.name""", fetch=True)
    return render_template("pages.html", page="medicines", medicines=rows)


@app.route("/medicines/add", methods=["GET", "POST"])
def medicines_add():
    if request.method == "POST":
        db("""INSERT INTO medicines (name,category,dosage_form,unit_price,stock_quantity,reorder_level,manufacturer)
              VALUES(%s,%s,%s,%s,%s,%s,%s)""",
            (request.form["name"], request.form.get("category"), request.form["dosage_form"],
             request.form["unit_price"], request.form["stock_quantity"],
             request.form["reorder_level"], request.form.get("manufacturer")))
        return redirect("/medicines/")
    return render_template("pages.html", page="medicine_form")


@app.route("/medicines/edit/<int:mid>", methods=["GET", "POST"])
def medicines_edit(mid):
    med = db("SELECT * FROM medicines WHERE medicine_id=%s", (mid,), one=True)
    if request.method == "POST":
        db("""UPDATE medicines SET name=%s,category=%s,dosage_form=%s,unit_price=%s,
              stock_quantity=%s,reorder_level=%s,manufacturer=%s WHERE medicine_id=%s""",
            (request.form["name"], request.form.get("category"), request.form["dosage_form"],
             request.form["unit_price"], request.form["stock_quantity"],
             request.form["reorder_level"], request.form.get("manufacturer"), mid))
        return redirect("/medicines/")
    return render_template("pages.html", page="medicine_form", medicine=med, edit=True)


@app.route("/medicines/delete/<int:mid>", methods=["POST"])
def medicines_delete(mid):
    db("DELETE FROM medicines WHERE medicine_id=%s", (mid,))
    return redirect("/medicines/")


# ==================== BILLING ====================
@app.route("/billing/")
def billing_list():
    bills = db("""SELECT b.*, p.name AS pn FROM bills b
                  JOIN patients p ON b.patient_id=p.patient_id ORDER BY b.bill_date DESC""", fetch=True)
    for b in bills:
        b["paid"] = db("SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE bill_id=%s",
                        (b["bill_id"],), one=True)["t"]
    return render_template("pages.html", page="billing", bills=bills)


@app.route("/billing/generate", methods=["GET", "POST"])
def billing_generate():
    apts = db("""SELECT a.appointment_id, p.patient_id, p.name AS pn, d.name AS dn, d.fee
                 FROM appointments a JOIN patients p ON a.patient_id=p.patient_id
                 JOIN doctors d ON a.doctor_id=d.doctor_id
                 WHERE a.appointment_id NOT IN (SELECT appointment_id FROM bills)
                 AND a.status IN ('Completed','Scheduled') ORDER BY a.appointment_date DESC""", fetch=True)
    error = None
    if request.method == "POST":
        try:
            db("SELECT * FROM generate_bill(%s)", (request.form["appointment_id"],))
            return redirect("/billing/")
        except Exception as e:
            error = str(e)
    return render_template("pages.html", page="billing_generate", apts=apts, error=error)


@app.route("/billing/pay/<int:bid>", methods=["POST"])
def billing_pay(bid):
    db("""INSERT INTO payments (bill_id,amount,payment_method,payment_date,reference_number)
          VALUES(%s,%s,%s,CURRENT_DATE,%s)""",
        (bid, request.form["amount"], request.form["payment_method"], request.form.get("reference_number", "")))
    return redirect("/billing/")


# ==================== REPORTS ====================
@app.route("/reports/")
def reports():
    return render_template("pages.html", page="reports")


@app.route("/reports/patients")
def reports_patients():
    r = db("""SELECT p.*, (SELECT COUNT(*) FROM appointments a WHERE a.patient_id=p.patient_id) AS ta,
              (SELECT COUNT(*) FROM treatments t WHERE t.patient_id=p.patient_id) AS tt,
              (SELECT COALESCE(SUM(b.total_amount),0) FROM bills b WHERE b.patient_id=p.patient_id) AS ts
              FROM patients p ORDER BY p.name""", fetch=True)
    return render_template("pages.html", page="reports", rt="patients", report=r)


@app.route("/reports/doctors")
def reports_doctors():
    r = db("""SELECT d.*, dept.name AS depn,
              (SELECT COUNT(*) FROM appointments a WHERE a.doctor_id=d.doctor_id) AS ta,
              (SELECT COALESCE(SUM(b.consultation_fee),0) FROM bills b
               JOIN appointments a ON b.appointment_id=a.appointment_id WHERE a.doctor_id=d.doctor_id) AS tr
              FROM doctors d JOIN departments dept ON d.dept_id=dept.dept_id ORDER BY dept.name, d.name""", fetch=True)
    return render_template("pages.html", page="reports", rt="doctors", report=r)


@app.route("/reports/appointments")
def reports_appointments():
    r = db("""SELECT a.*, p.name AS pn, d.name AS dn, dept.name AS depn
              FROM appointments a JOIN patients p ON a.patient_id=p.patient_id
              JOIN doctors d ON a.doctor_id=d.doctor_id JOIN departments dept ON d.dept_id=dept.dept_id
              ORDER BY a.appointment_date DESC""", fetch=True)
    return render_template("pages.html", page="reports", rt="appointments", report=r)


@app.route("/reports/revenue")
def reports_revenue():
    r = db("""SELECT TO_CHAR(payment_date,'YYYY-MM') AS month, COUNT(*) AS pc,
              SUM(amount) AS tr, AVG(amount) AS ap
              FROM payments GROUP BY TO_CHAR(payment_date,'YYYY-MM') ORDER BY month DESC""", fetch=True)
    return render_template("pages.html", page="reports", rt="revenue", report=r)


@app.route("/reports/medicines")
def reports_medicines():
    r = db("""SELECT m.*, CASE WHEN m.stock_quantity<=m.reorder_level THEN 'Low Stock' ELSE 'In Stock' END AS ss,
              (m.stock_quantity*m.unit_price) AS iv FROM medicines m ORDER BY m.stock_quantity ASC""", fetch=True)
    return render_template("pages.html", page="reports", rt="medicines", report=r)


# ==================== SQL DEMO ====================
QUERIES = {
    "dept_doctors": ("Department-wise Doctors",
        """SELECT dept.name AS department, COUNT(d.doctor_id) AS doctor_count,
           STRING_AGG(d.name, ', ') AS doctors
           FROM departments dept LEFT JOIN doctors d ON dept.dept_id=d.dept_id
           GROUP BY dept.name ORDER BY doctor_count DESC;"""),
    "doc_patients": ("Doctor-wise Patient Count",
        """SELECT d.name AS doctor_name, dept.name AS department,
           COUNT(DISTINCT a.patient_id) AS unique_patients, COUNT(a.appointment_id) AS total_appointments
           FROM doctors d JOIN departments dept ON d.dept_id=dept.dept_id
           LEFT JOIN appointments a ON d.doctor_id=a.doctor_id
           GROUP BY d.name, dept.name ORDER BY unique_patients DESC;"""),
    "monthly_rev": ("Monthly Revenue",
        """SELECT TO_CHAR(payment_date,'YYYY-MM') AS month, SUM(amount) AS total_revenue,
           COUNT(payment_id) AS payment_count FROM payments
           GROUP BY TO_CHAR(payment_date,'YYYY-MM') ORDER BY month DESC;"""),
    "highest_bill": ("Highest Bill",
        """SELECT b.bill_id, p.name AS patient_name, b.total_amount, b.bill_date, b.status
           FROM bills b JOIN patients p ON b.patient_id=p.patient_id
           WHERE b.total_amount=(SELECT MAX(total_amount) FROM bills);"""),
    "patient_history": ("Patient Treatment History",
        """SELECT p.name AS patient_name, t.diagnosis, t.treatment_details,
           t.treatment_date, d.name AS doctor_name
           FROM treatments t JOIN patients p ON t.patient_id=p.patient_id
           JOIN doctors d ON t.doctor_id=d.doctor_id ORDER BY p.name, t.treatment_date DESC;"""),
    "med_stock": ("Medicine Stock Report",
        """SELECT m.name AS medicine_name, m.category, m.stock_quantity, m.reorder_level, m.unit_price,
           (m.stock_quantity*m.unit_price) AS inventory_value,
           CASE WHEN m.stock_quantity<=m.reorder_level THEN 'LOW' ELSE 'OK' END AS status
           FROM medicines m ORDER BY m.stock_quantity ASC;"""),
    "upcoming": ("Upcoming Appointments",
        """SELECT a.appointment_id, p.name AS patient_name, d.name AS doctor_name,
           dept.name AS department, a.appointment_date, a.appointment_time, a.reason
           FROM appointments a JOIN patients p ON a.patient_id=p.patient_id
           JOIN doctors d ON a.doctor_id=d.doctor_id JOIN departments dept ON d.dept_id=dept.dept_id
           WHERE a.appointment_date>=CURRENT_DATE AND a.status='Scheduled'
           ORDER BY a.appointment_date, a.appointment_time;"""),
    "most_consulted": ("Most Consulted Doctors",
        """SELECT d.name AS doctor_name, dept.name AS department,
           COUNT(a.appointment_id) AS consultation_count,
           RANK() OVER (ORDER BY COUNT(a.appointment_id) DESC) AS rank
           FROM doctors d JOIN departments dept ON d.dept_id=dept.dept_id
           JOIN appointments a ON d.doctor_id=a.doctor_id
           GROUP BY d.name, dept.name ORDER BY consultation_count DESC;"""),
}


@app.route("/sql-demo/")
def sql_demo():
    return render_template("pages.html", page="sql_demo", queries=QUERIES, results=None, active=None, sql=None, title=None)


@app.route("/sql-demo/run/<key>")
def sql_demo_run(key):
    q = QUERIES.get(key)
    if not q:
        return render_template("pages.html", page="sql_demo", queries=QUERIES, results=None)
    try:
        results = db(q[1], fetch=True)
    except Exception as e:
        results = [{"error": str(e)}]
    return render_template("pages.html", page="sql_demo", queries=QUERIES, results=results, active=key, sql=q[1], title=q[0])


if __name__ == "__main__":
    app.run(debug=True, port=5000)
