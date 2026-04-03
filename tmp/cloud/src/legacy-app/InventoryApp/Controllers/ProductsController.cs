using System;
using System.Data.Entity;
using System.Linq;
using System.Net;
using System.Web.Mvc;
using InventoryApp.Models;

namespace InventoryApp.Controllers
{
    public class ProductsController : Controller
    {
        private readonly InventoryDbContext _db = new InventoryDbContext();

        // GET: Products
        public ActionResult Index()
        {
            var products = _db.Products.OrderBy(p => p.Name).ToList();
            return View(products);
        }

        // GET: Products/Create
        public ActionResult Create()
        {
            return View();
        }

        // POST: Products/Create
        [HttpPost]
        [ValidateAntiForgeryToken]
        public ActionResult Create(Product product)
        {
            if (ModelState.IsValid)
            {
                product.CreatedAt = DateTime.UtcNow;
                product.UpdatedAt = DateTime.UtcNow;
                _db.Products.Add(product);
                _db.SaveChanges();
                return RedirectToAction("Index");
            }
            return View(product);
        }

        // GET: Products/Edit/5
        public ActionResult Edit(int? id)
        {
            if (id == null)
                return new HttpStatusCodeResult(HttpStatusCode.BadRequest);

            var product = _db.Products.Find(id);
            if (product == null)
                return HttpNotFound();

            return View(product);
        }

        // POST: Products/Edit/5
        [HttpPost]
        [ValidateAntiForgeryToken]
        public ActionResult Edit(Product product)
        {
            if (ModelState.IsValid)
            {
                product.UpdatedAt = DateTime.UtcNow;
                _db.Entry(product).State = EntityState.Modified;
                _db.Entry(product).Property(p => p.CreatedAt).IsModified = false;
                _db.SaveChanges();
                return RedirectToAction("Index");
            }
            return View(product);
        }

        // GET: Products/Delete/5
        public ActionResult Delete(int? id)
        {
            if (id == null)
                return new HttpStatusCodeResult(HttpStatusCode.BadRequest);

            var product = _db.Products.Find(id);
            if (product == null)
                return HttpNotFound();

            return View(product);
        }

        // POST: Products/Delete/5
        [HttpPost, ActionName("Delete")]
        [ValidateAntiForgeryToken]
        public ActionResult DeleteConfirmed(int id)
        {
            var product = _db.Products.Find(id);
            if (product != null)
            {
                _db.Products.Remove(product);
                _db.SaveChanges();
            }
            return RedirectToAction("Index");
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
                _db.Dispose();

            base.Dispose(disposing);
        }
    }
}
